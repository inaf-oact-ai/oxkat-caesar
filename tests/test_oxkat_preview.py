"""Run with: python -m pytest -q tests/test_oxkat_preview.py"""
import json
import struct
from pathlib import Path

import numpy as np
from astropy.io import fits
import pytest

from oxkat_preview import generate


def make_image(root, name, data):
	p = root / name
	fits.PrimaryHDU(np.asarray(data, dtype=np.float32)).writeto(p)
	return p


def test_generates_small_previews_and_statistics(tmp_path):
	images = tmp_path / 'IMAGES'
	images.mkdir()
	out = tmp_path / 'results'
	out.mkdir()
	data = np.zeros((400, 512), dtype=np.float32)
	data[80, 220] = 15
	data[90, 220] = -3
	make_image(images, 'test-MFS-image.fits', data)
	result = generate(images, out)
	assert result['schema'] == 'caesar.oxkat-image-previews.v2'
	assert not result['errors']
	assert len(result['products']) == 1
	product = result['products'][0]
	assert product['image']['width'] == 512
	assert len(product['previews']) == 5
	assert product['statistics']['max_sample'] == 15.0
	for item in product['previews']:
		p = out / item['file']
		assert p.is_file()
		assert p.read_bytes().startswith(b'\x89PNG\r\n\x1a\n')
		assert p.stat().st_size < 3 * 1024 * 1024
	assert json.loads((out / 'image_qa.json').read_text()) == result
	assert (images / 'test-MFS-image.fits').is_file()


def test_mask_and_multidimensional_plane(tmp_path):
	images = tmp_path / 'IMAGES'
	images.mkdir()
	out = tmp_path / 'results'
	out.mkdir()
	data = np.zeros((1, 1, 128, 128), dtype=np.float32)
	data[0, 0, 14:35, 25:45] = 1
	make_image(images, 'target.mask0.fits', data)
	result = generate(images, out)
	assert result['products'][0]['is_mask'] is True
	assert result['products'][0]['image']['plane_indices'] == [0, 0]
	assert result['products'][0]['previews'][0]['stretch']['method'] == 'mask_positive'


def test_refuses_overwrite_or_symlinked_source(tmp_path):
	images = tmp_path / 'IMAGES'
	images.mkdir()
	out = tmp_path / 'results'
	out.mkdir()
	make_image(images, 'a.fits', np.ones((64, 64), dtype=np.float32))
	generate(images, out)
	with pytest.raises(FileExistsError):
		generate(images, out)
	(other := tmp_path / 'other.fits').write_bytes(b'not a FITS image')
	(images / 'unsafe.fits').symlink_to(other)
	with pytest.raises(ValueError, match='Unsafe FITS'):
		generate(images, tmp_path)


def test_nonfinite_image_records_failure(tmp_path):
	images = tmp_path / 'IMAGES'
	images.mkdir()
	out = tmp_path / 'results'
	out.mkdir()
	make_image(images, 'nan-MFS-image.fits', np.full((128,128), np.nan))
	result = generate(images, out)
	assert result['products'] == []
	assert len(result['errors']) == 1
	assert (out / 'image_qa.json').exists()


def test_filename_provenance_and_priority(tmp_path):
	images = tmp_path / 'IMAGES'
	images.mkdir()
	out = tmp_path / 'results'
	out.mkdir()
	name = 'img_measurement_set_1024ch_MAXIJ1348.ms_datablind-MFS-image.fits'
	make_image(images, name, np.ones((64, 64), dtype=np.float32))
	make_image(images, 'img_measurement_set_1024ch_MAXIJ1348.ms_datablind-MFS-residual.fits',
		np.ones((64, 64), dtype=np.float32))
	for index in range(8):
		make_image(images, 'img_measurement_set_1024ch_MAXIJ1348.ms_datablind-%04d-image.fits' % index,
			np.ones((64, 64), dtype=np.float32))
	result = generate(images, out, max_files=2)
	assert [item['product_kind'] for item in result['products']] == [
		'mfs_restored_image', 'mfs_residual'
	]
	first = result['products'][0]
	assert first['source_name'] == name
	assert first['previews'][0]['file'] == 'preview_%s__overview.png' % name[:-5]
	assert (out / first['previews'][0]['file']).is_file()


def test_positive_and_negative_peak_crops(tmp_path):
	images = tmp_path / 'IMAGES'
	images.mkdir()
	out = tmp_path / 'results'
	out.mkdir()
	data = np.zeros((512, 512), dtype=np.float32)
	data[80, 60] = 12
	data[400, 430] = -18
	make_image(images, 'science-MFS-image.fits', data)
	result = generate(images, out)
	assert result['schema'] == 'caesar.oxkat-image-previews.v2'
	previews = result['products'][0]['previews']
	kinds = {p['kind'] for p in previews}
	assert kinds == {'overview', 'center', 'peak_abs', 'peak_positive', 'peak_negative'}
	assert all((out / p['file']).exists() for p in previews)
	assert next(p for p in previews if p['kind'] == 'peak_negative')['file'].endswith('__peak_negative.png')


def test_source_finding_is_opt_in_and_only_one_restored_mfs(tmp_path, monkeypatch):
	import oxkat_preview
	images = tmp_path / 'IMAGES'
	images.mkdir()
	out = tmp_path / 'results'
	out.mkdir()
	data = np.ones((128, 128), dtype=np.float32)
	make_image(images, 'alpha-MFS-image.fits', data)
	make_image(images, 'beta-MFS-image.fits', data)
	make_image(images, 'gamma-MFS-residual.fits', data)
	calls = []
	def fake_source(path, output, identifier, **kwargs):
		calls.append(path.name)
		return {'status': 'complete', 'sources': {'component_count': 2}}
	monkeypatch.setattr(oxkat_preview, '_source_finding', fake_source)
	result = generate(images, out, source_finding=True)
	assert len(calls) == 1
	assert calls[0].endswith('-MFS-image.fits')
	assert result['products'][0]['source_finding']['sources']['component_count'] == 2
	assert 'source_finding' not in result['products'][1]


def test_optional_source_finding_failure_does_not_fail_preview(tmp_path, monkeypatch):
	import oxkat_preview
	images = tmp_path / 'IMAGES'
	images.mkdir()
	out = tmp_path / 'results'
	out.mkdir()
	make_image(images, 'alpha-MFS-image.fits', np.ones((128, 128), dtype=np.float32))
	def fail(*args, **kwargs):
		raise RuntimeError('BANE unavailable')
	monkeypatch.setattr(oxkat_preview, '_source_finding', fail)
	result = generate(images, out, source_finding=True)
	assert result['errors'] == []
	assert result['products'][0]['source_finding']['status'] == 'unavailable'
	assert (out / 'image_qa.json').exists()


def test_flux_statistics_summary(tmp_path):
	from astropy.table import Table
	from oxkat_preview import _catalog_summary
	catalog = tmp_path / 'components.fits'
	Table({'peak_flux': [1.0, 2.0, 4.0], 'int_flux': [1.2, 2.6, 5.0],
		'island': [1, 1, 2], 'ra': [100., 101., 102.],
		'dec': [-30., -31., -32.], 'local_rms': [0.1, 0.1, 0.2]}).write(catalog)
	result = _catalog_summary(catalog)
	assert result['component_count'] == 3
	assert result['island_count'] == 2
	assert result['peak_flux']['median'] == 2.0
	assert result['brightest_components'][0]['peak_flux'] == 4.0


def test_source_finding_failure_has_visible_progress_and_json_summary(tmp_path, monkeypatch, capsys):
	import oxkat_preview
	images = tmp_path / 'IMAGES'
	images.mkdir()
	out = tmp_path / 'results'
	out.mkdir()
	make_image(images, 'alpha-MFS-image.fits', np.ones((128, 128), dtype=np.float32))
	def failed(*args, **kwargs):
		raise RuntimeError('Aegean failed; see sourcefind_alpha-MFS-image__aegean.log')
	monkeypatch.setattr(oxkat_preview, '_source_finding', failed)
	result = generate(images, out, source_finding=True)
	assert result['source_finding_summary'] == {
		'requested': True, 'attempted': 1, 'completed': 0, 'unavailable': 1
	}
	assert 'Source finding UNAVAILABLE' in capsys.readouterr().err
	assert json.loads((out / 'image_qa.json').read_text())['source_finding_summary']['unavailable'] == 1


def test_scientific_subprocess_writes_durable_log(tmp_path, capsys):
	import sys
	from oxkat_preview import _run_scientific_tool
	log = tmp_path / 'BANE.log'
	elapsed = _run_scientific_tool(
		[sys.executable, '-c', 'print("synthetic BANE output")'],
		cwd=tmp_path, log_path=log, timeout=5, label='BANE')
	assert elapsed >= 0
	assert 'synthetic BANE output' in log.read_text()
	assert 'Exit status: 0' in log.read_text()
	assert 'BANE completed successfully' in capsys.readouterr().err


def test_scientific_subprocess_failure_preserves_log(tmp_path, capsys):
	import sys
	from oxkat_preview import _run_scientific_tool
	log = tmp_path / 'aegean.log'
	with pytest.raises(RuntimeError, match='exited with 7'):
		_run_scientific_tool(
			[sys.executable, '-c', 'print("catalog failure"); raise SystemExit(7)'],
			cwd=tmp_path, log_path=log, timeout=5, label='Aegean')
	assert 'catalog failure' in log.read_text()
	assert 'Exit status: 7' in log.read_text()
	assert 'Aegean FAILED' in capsys.readouterr().err
