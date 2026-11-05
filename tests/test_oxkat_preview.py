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
	assert result['schema'] == 'caesar.oxkat-image-previews.v1'
	assert not result['errors']
	assert len(result['products']) == 1
	product = result['products'][0]
	assert product['image']['width'] == 512
	assert len(product['previews']) == 3
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
