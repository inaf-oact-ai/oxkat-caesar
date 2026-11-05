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
import os
import re
from pathlib import Path
import struct
import sys
import tempfile
import zlib

import numpy as np
from astropy.io import fits

SCHEMA = 'caesar.oxkat-image-previews.v1'
MAX_FILES = 12
MAX_EDGE = 1024
MAX_CROP = 512
MAX_PIXEL_SAMPLES = 1024 * 1024


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


def _generate_one(path, out):
	data, meta = _read_plane(path)
	stats = _stats(data)
	mask = _product_kind(path.name) in ('initial_cleaning_mask', 'refined_cleaning_mask')
	identifier = _preview_identifier(path.name)
	positions = [('overview', data, [0, 0, int(data.shape[1]), int(data.shape[0])])]
	if min(data.shape) > 48:
		center, bounds = _crop(data, data.shape[1] // 2, data.shape[0] // 2, MAX_CROP)
		positions.append(('center', center, bounds))
		values = np.where(np.isfinite(data), np.abs(data), -np.inf)
		peak_y, peak_x = np.unravel_index(int(np.argmax(values)), data.shape)
		peak, bounds = _crop(data, int(peak_x), int(peak_y), MAX_CROP)
		positions.append(('peak_abs', peak, bounds))
	previews = []
	for kind, view, bounds in positions:
		pixels, stretch = _render(view, mask=mask)
		name = 'preview_%s__%s.png' % (identifier, kind)
		_atomic_new(out / name, _png_gray(pixels))
		previews.append({'kind': kind, 'file': name, 'sample_bounds': bounds,
			'pixels': [int(pixels.shape[1]), int(pixels.shape[0])], 'stretch': stretch})
	return {'source_name': path.name, 'source_size_bytes': path.stat().st_size,
		'product_id': identifier, 'product_kind': _product_kind(path.name), 'is_mask': mask, 'image': meta, 'statistics': stats,
		'previews': previews}


def generate(images, output, *, max_files=MAX_FILES):
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
	catalog = {'schema': SCHEMA, 'source_directory': 'IMAGES', 'products': [], 'errors': []}
	for path in files:
		try:
			catalog['products'].append(_generate_one(path, output))
		except Exception as exc:
			catalog['errors'].append({'source_name': path.name,
				'error': '%s: %s' % (type(exc).__name__, str(exc)[:150])})
	_atomic_new(output / 'image_qa.json', (json.dumps(catalog, indent=2, allow_nan=False) + '\n').encode('utf-8'))
	return catalog


def main(argv=None):
	parser = argparse.ArgumentParser(description=__doc__)
	parser.add_argument('--images', required=True, help='Existing IMAGES directory')
	parser.add_argument('--outdir', required=True, help='Existing output directory')
	parser.add_argument('--max-files', type=int, default=MAX_FILES)
	args = parser.parse_args(argv)
	try:
		result = generate(args.images, args.outdir, max_files=args.max_files)
	except Exception as exc:
		print('ERROR: %s' % exc, file=sys.stderr)
		return 2
	print('OXKAT image previews: %d products, %d errors' %
		(len(result['products']), len(result['errors'])))
	return 0 if not result['errors'] else 1


if __name__ == '__main__':
	sys.exit(main())
