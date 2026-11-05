#!/usr/bin/env python3
"""Bounded, deterministic FITS previews for OXKAT published IMAGES.

No Mutation of source FITS. Generate previews before artifact registration and
retention; existing retained products MUST be handled via separate export dirs.
Only numpy and astropy plus Python standard library are needed.
"""
import argparse
import hashlib
import json
import math
import datetime
import signal
import time
import os
import re
import shutil
import subprocess
from pathlib import Path
import struct
import sys
import tempfile
import zlib

import numpy as np
from astropy.io import fits
from astropy.table import Table
from astropy.wcs import WCS

SCHEMA = 'caesar.oxkat-image-previews.v2'
MAX_FILES = 12
MAX_EDGE = 1024
MAX_CROP = 512
MAX_PIXEL_SAMPLES = 1024 * 1024
SOURCE_FINDING_TIMEOUT = 1200
MAX_SOURCE_FINDING_IMAGES = 1
SOURCE_FINDING_HEARTBEAT = 20


def _progress(message):
	stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
	print('[OXKAT preview %s] %s' % (stamp, message), file=sys.stderr, flush=True)


def _png_gray(pixels):
	"""Encode 8-bit grayscale PNG without a graphics/UI dependency."""
	pixels = np.ascontiguousarray(pixels, dtype=np.uint8)
	h, w = pixels.shape
	def chunk(tag, payload):
		return struct.pack('!I', len(payload)) + tag + payload + struct.pack('!I', zlib.crc32(tag + payload) & 0xffffffff)
	raw = b''.join(b'\0' + pixels[row].tobytes() for row in range(h))
	return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!IIBBBBB', w, h, 8, 0, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw, 6)) + chunk(b'IEND', b''))


def _atomic_new(path, data):
	"""Publish only absent files. Never replace previous run products."""
	fd, temp = tempfile.mkstemp(prefix='.preview-pending-', dir=str(path.parent))
	try:
		with os.fdopen(fd, 'wb') as fp:
			fp.write(data)
			fp.flush()
			os.fsync(fp.fileno())
		if path.exists() or path.is_symlink():
			raise FileExistsError('Output already exists: %s' % path.name)
		os.link(temp, path, follow_symlinks=False)
	finally:
		if os.path.exists(temp):
			os.unlink(temp)


def _product_kind(name):
	"""Classify WSClean/OXKAT products using their documented suffixes."""
	n = name.lower()
	if n.endswith('.mask0.fits'):
		return 'initial_cleaning_mask'
	if n.endswith('.mask1.fits'):
		return 'refined_cleaning_mask'
	if n.endswith('-mfs-image.pbcor.fits'):
		return 'mfs_primary_beam_corrected_image'
	if n.endswith('-mfs-image.pb.fits'):
		return 'mfs_primary_beam_response'
	if n.endswith('-mfs-image.wt.fits'):
		return 'mfs_weight_map'
	for suffix, kind in (
		('-mfs-image.fits', 'mfs_restored_image'),
		('-mfs-residual.fits', 'mfs_residual'),
		('-mfs-dirty.fits', 'mfs_dirty_image'),
		('-mfs-model.fits', 'mfs_model'),
		('-mfs-psf.fits', 'mfs_point_spread_function'),
	):
		if n.endswith(suffix):
			return kind
	return 'spectral_plane_or_other'


_PRIORITY = {
	'mfs_primary_beam_corrected_image': 0,
	'mfs_restored_image': 1,
	'mfs_residual': 2,
	'initial_cleaning_mask': 3,
	'refined_cleaning_mask': 3,
	'mfs_dirty_image': 4,
	'mfs_model': 5,
	'mfs_point_spread_function': 6,
	'mfs_primary_beam_response': 7,
	'mfs_weight_map': 8,
	'spectral_plane_or_other': 9,
}


def _preview_identifier(source_name):
	"""Prefer the intact FITS stem; hash only on pathological long names."""
	stem = Path(source_name).stem
	if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*', stem):
		raise ValueError('Unsupported FITS basename: %s' % source_name)
	# Keep generated names below typical 255-byte filesystem limits.
	if len(stem.encode('utf-8')) > 175:
		stem = stem[:150] + '__' + hashlib.sha256(source_name.encode('utf-8')).hexdigest()[:16]
	return stem


def _source_files(images, limit):
	if images.is_symlink() or not images.is_dir():
		raise ValueError('IMAGES must be an ordinary directory')
	files = []
	for child in images.iterdir():
		if child.suffix.lower() not in ('.fits', '.fit', '.fts'):
			continue
		if child.is_symlink() or not child.is_file():
			raise ValueError('Unsafe FITS entry in IMAGES: %s' % child.name)
		files.append(child)
	return sorted(files, key=lambda p: (_PRIORITY[_product_kind(p.name)], p.name.lower()))[:limit]


def _read_plane(src):
	"""Select first image HDU; select index zero on all non-spatial axes."""
	with fits.open(str(src), memmap=True, do_not_scale_image_data=False) as hdus:
		for hdu in hdus:
			if hdu.data is None or hdu.data.ndim < 2:
				continue
			shape = hdu.data.shape
			if any(n < 1 for n in shape) or shape[-2] < 2 or shape[-1] < 2:
				continue
			data = hdu.data
			height, width = shape[-2:]
			step = max(1, math.ceil(max(height, width) / MAX_EDGE))
			index = (0,) * (data.ndim - 2)
			# FITS objects may be memmapped; materialize only the sampled plane.
			view = np.array(data[index + (slice(None, None, step), slice(None, None, step))], dtype=np.float64)
			if view.size > MAX_PIXEL_SAMPLES:
				raise ValueError('Sample exceeds preview pixel limit')
			meta = {'width': int(width), 'height': int(height), 'naxis': int(data.ndim),
				'plane_indices': [0] * (data.ndim - 2),
				'sample_step': int(step), 'bunit': str(hdu.header.get('BUNIT', ''))[:100],
				'bmaj_deg': _number(hdu.header.get('BMAJ')),
				'bmin_deg': _number(hdu.header.get('BMIN')),
				'crval1_deg': _number(hdu.header.get('CRVAL1')),
				'crval2_deg': _number(hdu.header.get('CRVAL2'))}
			return view, meta
		raise ValueError('No suitable 2D FITS image plane')


def _number(x):
	try:
		v = float(x)
		return v if math.isfinite(v) else None
	except (TypeError, ValueError):
		return None


def _stats(data):
	valid = data[np.isfinite(data)]
	if not valid.size:
		raise ValueError('No finite image pixels')
	median = float(np.median(valid))
	mad = float(np.median(np.abs(valid - median)))
	return {'sampled_pixel_count': int(data.size), 'finite_sample_count': int(valid.size),
		'nan_fraction_sample': float(1 - valid.size / data.size),
		'min_sample': float(np.min(valid)), 'max_sample': float(np.max(valid)),
		'median_sample': median, 'robust_rms_sample': float(1.4826 * mad),
		'p01_sample': float(np.percentile(valid, 1)),
		'p99_sample': float(np.percentile(valid, 99)),
		'method': 'strided-plane-sample; median absolute deviation x 1.4826'}


def _render(data, mask=False):
	finite = np.isfinite(data)
	valid = data[finite]
	if not valid.size:
		raise ValueError('No finite image pixels')
	if mask:
		return np.where(finite & (data > 0), 255, 0).astype(np.uint8), {'method': 'mask_positive'}
	low, high = [float(x) for x in np.percentile(valid, (1, 99))]
	if high <= low:
		high = low + max(abs(low) * 0.01, 1e-12)
	clipped = np.clip(np.nan_to_num(data, nan=low, posinf=high, neginf=low), low, high)
	normalized = (clipped - low) / (high - low)
	# Asinh stretch reveals faint structures while retaining bright sources.
	image = np.rint(255 * np.arcsinh(10.0 * normalized) / np.arcsinh(10.0)).astype(np.uint8)
	return image, {'method': 'asinh_percentile', 'p01': low, 'p99': high, 'asinh_scale': 10.0}


def _crop(data, x, y, size):
	h, w = data.shape
	half = min(size, h, w) // 2
	x0 = max(0, min(w - 2 * half, x - half))
	y0 = max(0, min(h - 2 * half, y - half))
	return data[y0:y0 + 2 * half, x0:x0 + 2 * half], [int(x0), int(y0), int(2 * half), int(2 * half)]


def _generate_one(path, out, *, identifier=None, product_kind=None):
	
	data, meta = _read_plane(path)
	stats = _stats(data)
	
	if product_kind is None:
		product_kind = _product_kind(path.name)
	
	mask = product_kind in ('initial_cleaning_mask', 'refined_cleaning_mask')
	if identifier is None:
		identifier = _preview_identifier(path.name)
	
	positions = [('overview', data, [0, 0, int(data.shape[1]), int(data.shape[0])])]
	if min(data.shape) > 48:
		center, bounds = _crop(data, data.shape[1] // 2, data.shape[0] // 2, MAX_CROP)
		positions.append(('center', center, bounds))
		values = np.where(np.isfinite(data), np.abs(data), -np.inf)
		peak_y, peak_x = np.unravel_index(int(np.argmax(values)), data.shape)
		peak, bounds = _crop(data, int(peak_x), int(peak_y), MAX_CROP)
		positions.append(('peak_abs', peak, bounds))
		positive = np.where(np.isfinite(data), data, -np.inf)
		negative = np.where(np.isfinite(data), data, np.inf)
		for label, array, take_min in (('peak_positive', positive, False), ('peak_negative', negative, True)):
			location = np.argmin(array) if take_min else np.argmax(array)
			py, px = np.unravel_index(int(location), data.shape)
			view, cbounds = _crop(data, int(px), int(py), MAX_CROP)
			positions.append((label, view, cbounds))
	previews = []
	for kind, view, bounds in positions:
		pixels, stretch = _render(view, mask=mask)
		name = 'preview_%s__%s.png' % (identifier, kind)
		_atomic_new(out / name, _png_gray(pixels))
		previews.append({'kind': kind, 'file': name, 'sample_bounds': bounds,
			'pixels': [int(pixels.shape[1]), int(pixels.shape[0])], 'stretch': stretch})
	return {'source_name': path.name, 'source_size_bytes': path.stat().st_size,
		'product_id': identifier, 'product_kind': product_kind, 'is_mask': mask, 'image': meta, 'statistics': stats,
		'previews': previews}


def _map_preview(path, out, identifier, label):
	"""Generate the standard five-view preview set for a BANE FITS map."""
	return _generate_one(
		path,
		out,
		identifier='%s__%s' % (identifier, label),
		product_kind='bane_%s_map' % label
	)

def _catalog_summary(path, *, limit=10):
	"""Summarize an Aegean tab-separated component catalog."""
	components = Table.read(str(path), format='ascii.tab')
	count = len(components)
	cols = set(components.colnames)
	def finite_column(name):
		if name not in cols:
			return np.array([], dtype=np.float64)
		values = np.ma.filled(np.ma.asarray(components[name], dtype=np.float64), np.nan)
		return np.asarray(values[np.isfinite(values)], dtype=np.float64)
	peak = finite_column('peak_flux')
	integrated = finite_column('int_flux')
	result = {'component_count': int(count), 'island_count': None,
		'flux_unit_peak': 'Jy/beam', 'flux_unit_integrated': 'Jy',
		'peak_flux': _distribution(peak), 'integrated_flux': _distribution(integrated)}
	if 'island' in cols:
		result['island_count'] = int(len(set(str(x) for x in components['island'])))
	if count and peak.size and 'peak_flux' in cols:
		values = np.ma.filled(np.ma.asarray(components['peak_flux'], dtype=float), np.nan)
		order = np.argsort(np.nan_to_num(values, nan=-np.inf))[::-1]
		bright = []
		for index in order[:limit]:
			if not np.isfinite(values[index]):
				continue
			item = {'peak_flux': float(values[index])}
			for key in ('ra', 'dec', 'int_flux', 'local_rms'):
				if key in cols:
					v = _number(components[key][index])
					if v is not None:
						item[key] = v
			bright.append(item)
		result['brightest_components'] = bright
	return result


def _distribution(values):
	if not values.size:
		return {'count': 0}
	q = np.percentile(values, [0, 10, 25, 50, 75, 90, 100])
	return {'count': int(values.size), 'min': float(q[0]), 'p10': float(q[1]),
		'p25': float(q[2]), 'median': float(q[3]), 'p75': float(q[4]),
		'p90': float(q[5]), 'max': float(q[6])}


def _brightest_source_preview(path, sources, out, identifier):
	"""Crop around the brightest detected Aegean source using FITS WCS."""
	bright = sources.get('brightest_components') or []
	if not bright or 'ra' not in bright[0] or 'dec' not in bright[0]:
		return {'status': 'unavailable', 'reason': 'no sky coordinates in source catalog'}
	with fits.open(str(path), memmap=True) as hdus:
		header = next((hdu.header for hdu in hdus if hdu.data is not None and hdu.data.ndim >= 2), None)
		if header is None:
			return {'status': 'unavailable', 'reason': 'no image HDU'}
		try:
			x_full, y_full = WCS(header).celestial.world_to_pixel_values(
				bright[0]['ra'], bright[0]['dec'])
		except Exception as exc:
			return {'status': 'unavailable', 'reason': 'cannot project source coordinates: %s' % type(exc).__name__}
	data, meta = _read_plane(path)
	step = meta['sample_step']
	x, y = int(round(float(x_full) / step)), int(round(float(y_full) / step))
	if not (0 <= x < data.shape[1] and 0 <= y < data.shape[0]):
		return {'status': 'unavailable', 'reason': 'brightest catalog source outside sampled image'}
	view, bounds = _crop(data, x, y, MAX_CROP)
	pixels, stretch = _render(view)
	filename = 'preview_%s__brightest_source.png' % identifier
	_atomic_new(out / filename, _png_gray(pixels))
	return {'status': 'complete', 'file': filename, 'sample_bounds': bounds,
		'center_ra_deg': bright[0]['ra'], 'center_dec_deg': bright[0]['dec'],
		'stretch': stretch}


def _run_scientific_tool(args, *, cwd, log_path, timeout, label):
	"""Run a scientific subprocess with a durable log and progress heartbeat.

	Do not buffer multi-minute BANE/Aegean output in Python memory.
	A timeout terminates the process group, including its child processes.
	"""
	started = time.monotonic()
	_progress('%s starting; detailed log: %s' % (label, log_path))
	with open(log_path, 'x', encoding='utf-8') as stream:
		stream.write('# OXKAT source finding: %s\n' % label)
		stream.write('# UTC start: %s\n' % datetime.datetime.now(datetime.timezone.utc).isoformat())
		stream.write('# Command: %s\n' % ' '.join(args))
		stream.flush()
		proc = subprocess.Popen(args, cwd=str(cwd), stdin=subprocess.DEVNULL,
			stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
		try:
			while True:
				remaining = timeout - (time.monotonic() - started)
				if remaining <= 0:
					raise subprocess.TimeoutExpired(args, timeout)
				try:
					code = proc.wait(timeout=min(SOURCE_FINDING_HEARTBEAT, remaining))
					break
				except subprocess.TimeoutExpired:
					_progress('%s still running (%.0f s); log: %s' % (
						label, time.monotonic() - started, log_path))
		except subprocess.TimeoutExpired:
			_progress('%s timed out after %.0f s; stopping process group' % (
				label, time.monotonic() - started))
			try:
				os.killpg(proc.pid, signal.SIGTERM)
			except ProcessLookupError:
				pass
			try:
				proc.wait(timeout=5)
			except subprocess.TimeoutExpired:
				try:
					os.killpg(proc.pid, signal.SIGKILL)
				except ProcessLookupError:
					pass
				proc.wait()
			raise RuntimeError('%s timed out; see %s' % (label, log_path.name))
		stream.write('\n# Exit status: %d\n' % code)
		stream.flush()
	elapsed = time.monotonic() - started
	if code != 0:
		_progress('%s FAILED (exit %d, %.1f s); see %s' % (label, code, elapsed, log_path))
		raise RuntimeError('%s exited with %d; see %s' % (label, code, log_path.name))
	_progress('%s completed successfully (%.1f s)' % (label, elapsed))
	return elapsed

def _retain_catalog(source, output, filename):
	"""Retain an Aegean catalog without overwriting existing products."""
	source = Path(source)
	destination = output / filename

	if not source.is_file():
		raise RuntimeError(
			'Expected Aegean catalog not generated: %s' % source.name
		)

	with source.open('rb') as reader:
		with destination.open('xb') as writer:
			try:
				shutil.copyfileobj(reader, writer, length=1024 * 1024)
			except BaseException:
				writer.close()
				destination.unlink()
				raise

	return filename
	
def _source_finding(path, output, identifier, *, scratch_dir=None, timeout=SOURCE_FINDING_TIMEOUT):
	"""Run BANE/Aegean, publish previews and retain ASCII/DS9 catalogs."""

	for executable in ('BANE', 'aegean'):
		if shutil.which(executable) is None:
			raise RuntimeError('%s executable not installed in scientific image' % executable)

	with tempfile.TemporaryDirectory(prefix='oxkat-sourcefind-', dir=scratch_dir) as work:
		workpath = Path(work)

		prefix = workpath / 'bane'
		background = workpath / 'bane_bkg.fits'
		rms = workpath / 'bane_rms.fits'

		catalog_base = workpath / 'aegean_catalog'
		catalog_native = workpath / 'aegean_catalog.dat'
		catalog_tab = workpath / 'aegean_catalog.tab'
		catalog_reg = workpath / 'aegean_catalog.reg'

		log_bane = output / ('sourcefind_%s__BANE.log' % identifier)
		log_aegean = output / ('sourcefind_%s__aegean.log' % identifier)

		_progress('Source finding selected %s' % path.name)

		bane_seconds = _run_scientific_tool(
			[
				'BANE', str(path),
				'--out', str(prefix),
				'--cores', '1'
			],
			cwd=workpath,
			log_path=log_bane,
			timeout=timeout,
			label='BANE'
		)

		if not background.is_file() or not rms.is_file():
			raise RuntimeError(
				'BANE finished without expected background/RMS FITS maps; see %s'
				% log_bane.name
			)

		_progress('BANE maps ready; generating standard map previews')

		result = {
			'status': 'complete',
			'algorithm': 'BANE+AEGEAN',
			'logs': {
				'bane': log_bane.name,
				'aegean': log_aegean.name
			},
			'duration_seconds': {
				'bane': round(bane_seconds, 2)
			}
		}

		result['background'] = _map_preview(
			background, output, identifier, 'background'
		)

		result['rms'] = _map_preview(
			rms, output, identifier, 'rms'
		)

		_progress('BANE previews completed; starting Aegean detection')

		aegean_seconds = _run_scientific_tool(
			[
				'aegean', str(path),
				'--find',
				'--cores', '1',
				'--slice', '0',
				'--noise', str(rms),
				'--background', str(background),
				'--maxsummits', '5',
				'--seedclip', '5',
				'--floodclip', '4',
				'--island',
				'--out', str(catalog_native),
				'--table', '%s,%s' % (catalog_reg, catalog_tab)
			],
			cwd=workpath,
			log_path=log_aegean,
			timeout=timeout,
			label='Aegean'
		)

		result['duration_seconds']['aegean'] = round(aegean_seconds, 2)

		component_tab = Path('%s_comp.tab' % catalog_base)
		island_tab = Path('%s_isle.tab' % catalog_base)
		component_reg = Path('%s_comp.reg' % catalog_base)
		island_reg = Path('%s_isle.reg' % catalog_base)

		# Aegean writes _comp and _isle outputs only when
		# corresponding catalog entries are available.
		catalog_files = {
			'native_ascii': catalog_native,
			'components_ascii': component_tab,
			'islands_ascii': island_tab,
			'components_ds9': component_reg,
			'islands_ds9': island_reg
		}

		# The native ASCII listing is produced by --out even when
		# there are no fitted sources.
		if not catalog_native.is_file():
			raise RuntimeError(
				'Aegean finished without native ASCII catalog; see %s'
				% log_aegean.name
			)

		# Source counts and statistics are derived before scratch cleanup.
		if component_tab.is_file():
			sources = _catalog_summary(component_tab)
		else:
			sources = {
				'component_count': 0,
				'island_count': 0,
				'peak_flux': {'count': 0},
				'integrated_flux': {'count': 0}
			}

		if island_tab.is_file():
			islands = Table.read(str(island_tab), format='ascii.tab')
			sources['island_count'] = int(len(islands))

			for key in ('island_flux', 'island_rms'):
				if key in islands.colnames:
					values = np.ma.filled(
						np.ma.asarray(islands[key], dtype=np.float64),
						np.nan
					)
					values = values[np.isfinite(values)]
					sources[key] = _distribution(values)

		result['sources'] = sources

		# Retain every catalog generated by Aegean.
		retained = {}

		for kind, source in catalog_files.items():
			if not source.is_file():
				retained[kind] = None
				continue

			extension = source.suffix
			filename = 'sourcefind_%s__%s%s' % (
				identifier, kind, extension
			)

			retained[kind] = _retain_catalog(
				source, output, filename
			)

		result['catalogs'] = retained

		result['brightest_source_preview'] = _brightest_source_preview(
			path, sources, output, identifier
		)

		_progress(
			'Aegean catalog summarized: %d components, %s islands'
			% (
				sources['component_count'],
				sources['island_count']
			)
		)

		return result


def generate(images, output, *, max_files=MAX_FILES, source_finding=False, scratch_dir=None):
	images = Path(images).absolute()
	output = Path(output).absolute()
	if output.is_symlink() or not output.is_dir():
		raise ValueError('Output must be an existing ordinary directory')
	if images == output or output == images.parent or images in output.parents:
		# Normal job path is results/IMAGES -> results; allowed (and intended).
		if images == output or images in output.parents:
			raise ValueError('Output must not be inside the scientific IMAGES directory')
	if not 1 <= max_files <= MAX_FILES:
		raise ValueError('max_files outside supported range')
	if (output / 'image_qa.json').exists() or (output / 'image_qa.json').is_symlink():
		raise FileExistsError('image_qa.json already exists')
	files = _source_files(images, max_files)
	_progress('Found %d selected FITS products; source finding: %s' % (len(files), 'enabled' if source_finding else 'disabled'))
	catalog = {'schema': SCHEMA, 'source_directory': 'IMAGES', 'products': [], 'errors': []}
	source_finding_done = 0
	for index, path in enumerate(files, 1):
		_progress('Previewing FITS %d/%d: %s' % (index, len(files), path.name))
		try:
			product = _generate_one(path, output)
			catalog['products'].append(product)
			if (source_finding and source_finding_done < MAX_SOURCE_FINDING_IMAGES
					and product['product_kind'] == 'mfs_restored_image'):
				source_finding_done += 1
				try:
					product['source_finding'] = _source_finding(path, output,
						product['product_id'], scratch_dir=scratch_dir)
				except Exception as exc:
					_progress('Source finding UNAVAILABLE for %s: %s: %s' % (path.name, type(exc).__name__, exc))
					product['source_finding'] = {'status': 'unavailable',
						'error': '%s: %s' % (type(exc).__name__, str(exc)[:250])}
		except Exception as exc:
			_progress('Preview generation FAILED for %s: %s: %s' % (path.name, type(exc).__name__, exc))
			catalog['errors'].append({'source_name': path.name,
				'error': '%s: %s' % (type(exc).__name__, str(exc)[:150])})
	if source_finding and source_finding_done == 0:
		_progress('Source finding NOT ATTEMPTED: no successfully previewed restored MFS image selected')
	catalog['source_finding_summary'] = {
		'requested': bool(source_finding),
		'attempted': source_finding_done,
		'completed': sum(p.get('source_finding', {}).get('status') == 'complete' for p in catalog['products']),
		'unavailable': sum(p.get('source_finding', {}).get('status') == 'unavailable' for p in catalog['products'])
	}
	_atomic_new(output / 'image_qa.json', (json.dumps(catalog, indent=2, allow_nan=False) + '\n').encode('utf-8'))
	return catalog


def main(argv=None):
	parser = argparse.ArgumentParser(description=__doc__)
	parser.add_argument('--images', required=True, help='Existing IMAGES directory')
	parser.add_argument('--outdir', required=True, help='Existing output directory')
	parser.add_argument('--max-files', type=int, default=MAX_FILES)
	parser.add_argument('--source-finding', action='store_true',
		help='Run optional BANE/Aegean on one restored MFS image (may be slow)')
	parser.add_argument('--scratch-dir',
		help='Existing writable temporary filesystem with space for BANE FITS maps')
	args = parser.parse_args(argv)
	try:
		result = generate(args.images, args.outdir, max_files=args.max_files,
				source_finding=args.source_finding, scratch_dir=args.scratch_dir)
	except Exception as exc:
		print('ERROR: %s' % exc, file=sys.stderr)
		return 2
	sf = result['source_finding_summary']
	print('OXKAT image previews: %d products, %d preview errors; source finding: requested=%s, attempted=%d, completed=%d, unavailable=%d' %
		(len(result['products']), len(result['errors']), sf['requested'], sf['attempted'], sf['completed'], sf['unavailable']))
	# An unavailable optional source finder does not invalidate an otherwise successful run.
	return 0 if not result['errors'] else 1


if __name__ == '__main__':
	sys.exit(main())
