
#!/usr/bin/env python3
"""Regression tests for OXKAT imaging-family preview selection.

Run from the oxkat-caesar repository root:

    PYTHONPATH=helpers python -m pytest -q \
        tests/test_oxkat_preview_families.py
"""

import json

import numpy as np
import pytest
from astropy.io import fits

import oxkat_preview


def make_image(images, name, value=1.0):
	"""Create a small synthetic FITS image."""
	path = images / name
	data = np.full((64, 64), value, dtype=np.float32)
	data[20, 30] = value + 5.0
	fits.PrimaryHDU(data).writeto(path)
	return path


def make_directories(tmp_path):
	images = tmp_path / "IMAGES"
	output = tmp_path / "results"
	images.mkdir()
	output.mkdir()
	return images, output


def test_all_families_without_default_limit(tmp_path):
	"""Every FITS product must be previewed, not just the first 12."""
	images, output = make_directories(tmp_path)

	for family in ("datablind", "datamask", "pcalmask"):
		for index in range(5):
			make_image(
				images,
				f"target.ms_{family}-{index:04d}-image.fits",
				value=float(index + 1),
			)

	result = oxkat_preview.generate(images, output)

	assert result["errors"] == []
	assert len(result["products"]) == 15
	assert len(result["imaging_families"]) == 3

	families = {
		item["name"]: item["product_count"]
		for item in result["imaging_families"]
	}

	assert families == {
		"pcalmask": 5,
		"datamask": 5,
		"datablind": 5,
	}

	for product in result["products"]:
		assert len(product["previews"]) == 5

		for preview in product["previews"]:
			assert (output / preview["file"]).is_file()

	assert len(list(output.glob("preview_*.png"))) == 75

	saved = json.loads(
		(output / "image_qa.json").read_text(encoding="utf-8")
	)
	assert saved == result


def test_pcalmask_selected_for_source_finding(tmp_path, monkeypatch):
	"""Source finding must prefer pcalmask over datamask/datablind."""
	images, output = make_directories(tmp_path)

	for family in ("datablind", "datamask", "pcalmask"):
		make_image(
			images,
			f"target.ms_{family}-MFS-image.fits",
		)
		make_image(
			images,
			f"target.ms_{family}-MFS-image.pbcor.fits",
		)

	calls = []

	def fake_source_finding(path, output_dir, identifier, **kwargs):
		calls.append({
			"filename": path.name,
			"identifier": identifier,
		})
		return {
			"status": "complete",
			"sources": {
				"component_count": 3,
				"island_count": 2,
			},
		}

	monkeypatch.setattr(
		oxkat_preview,
		"_source_finding",
		fake_source_finding,
	)

	result = oxkat_preview.generate(
		images,
		output,
		source_finding=True,
	)

	expected = "target.ms_pcalmask-MFS-image.fits"

	assert len(calls) == 1
	assert calls[0]["filename"] == expected

	selection = result["imaging_selection"]

	assert selection["selected_family"] == "pcalmask"
	assert selection["source_finding_input"] == expected

	assert result["source_finding_summary"] == {
		"requested": True,
		"attempted": 1,
		"completed": 1,
		"unavailable": 0,
	}

	selected_products = [
		product
		for product in result["products"]
		if "source_finding" in product
	]

	assert len(selected_products) == 1
	assert selected_products[0]["source_name"] == expected
	assert selected_products[0]["imaging_family"] == "pcalmask"

	# PB-corrected images are previewed but not used for detection.
	pbcor_products = [
		product
		for product in result["products"]
		if product["product_kind"] == "mfs_primary_beam_corrected_image"
	]

	assert len(pbcor_products) == 3
	assert all(
		"source_finding" not in product
		for product in pbcor_products
	)


@pytest.mark.parametrize(
	"available_families,expected_family",
	[
		(("datablind", "datamask"), "datamask"),
		(("datablind",), "datablind"),
	],
)
def test_source_finding_family_fallback(
	tmp_path,
	monkeypatch,
	available_families,
	expected_family,
):
	"""Fallback must select the best available restored MFS family."""
	images, output = make_directories(tmp_path)

	for family in available_families:
		make_image(
			images,
			f"target.ms_{family}-MFS-image.fits",
		)

	calls = []

	def fake_source_finding(path, output_dir, identifier, **kwargs):
		calls.append(path.name)
		return {"status": "complete"}

	monkeypatch.setattr(
		oxkat_preview,
		"_source_finding",
		fake_source_finding,
	)

	result = oxkat_preview.generate(
		images,
		output,
		source_finding=True,
	)

	expected_name = (
		f"target.ms_{expected_family}-MFS-image.fits"
	)

	assert calls == [expected_name]
	assert result["imaging_selection"]["selected_family"] == expected_family
	assert result["source_finding_summary"]["completed"] == 1


def test_unclassified_fits_are_still_previewed(tmp_path):
	"""Unknown naming patterns must not exclude valid FITS products."""
	images, output = make_directories(tmp_path)

	make_image(images, "independent_image.fits")
	make_image(images, "target.ms_pcalmask-MFS-image.fits")

	result = oxkat_preview.generate(images, output)

	assert result["errors"] == []
	assert len(result["products"]) == 2

	families = {
		item["name"]
		for item in result["imaging_families"]
	}

	assert families == {"pcalmask", "unclassified"}

	unclassified = [
		product
		for product in result["products"]
		if product["imaging_family"] == "unclassified"
	]

	assert len(unclassified) == 1
	assert unclassified[0]["source_name"] == "independent_image.fits"
	assert len(unclassified[0]["previews"]) == 5


def test_explicit_file_limit_remains_available(tmp_path):
	"""An explicit file limit may still be used for diagnostic runs."""
	images, output = make_directories(tmp_path)

	for index in range(6):
		make_image(
			images,
			f"target.ms_pcalmask-{index:04d}-image.fits",
		)

	result = oxkat_preview.generate(
		images,
		output,
		max_files=2,
	)

	assert len(result["products"]) == 2
	assert result["errors"] == []


def test_zoomed_refined_mask_classification(tmp_path):
	"""Zoomed mask1 FITS products must use binary mask rendering."""
	images, output = make_directories(tmp_path)

	make_image(
		images,
		"target.ms_pcalmask-MFS-image.mask1.zoom10125.fits",
	)

	result = oxkat_preview.generate(images, output)

	assert result["errors"] == []
	assert len(result["products"]) == 1

	product = result["products"][0]

	assert product["imaging_family"] == "pcalmask"
	assert product["product_kind"] == "refined_cleaning_mask"
	assert product["is_mask"] is True

	assert all(
		preview["stretch"]["method"] == "mask_positive"
		for preview in product["previews"]
	)

