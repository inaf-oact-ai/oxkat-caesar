import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'helpers'))
from oxkat_preview_layout import organize


def test_layout_and_selected(tmp_path):
	root = tmp_path / 'previews'
	full = root / 'all'
	full.mkdir(parents=True)
	names = {
		'overview': 'preview_target-MFS-image__overview.png',
		'center': 'preview_target-MFS-image__center.png',
		'peak_positive': 'preview_target-MFS-image__peak_positive.png',
		'peak_abs': 'preview_target-MFS-image__peak_abs.png',
	}
	for name in names.values():
		(full / name).write_bytes(b'PNG')
	(full / 'sourcefind_target__BANE.log').write_text('ok')
	(full / 'sourcefind_target__components_ascii.tab').write_text('tab')
	qa = {'schema': 'x', 'products': [{
		'product_kind': 'mfs_restored_image',
		'previews': [{'kind': k, 'file': v} for k, v in names.items()],
		'source_finding': {'logs': {'bane': 'sourcefind_target__BANE.log'},
                           'catalogs': {'components_ascii': 'sourcefind_target__components_ascii.tab'}}
	}], 'imaging_families': [{'name': 'test'}]}
	(full / 'image_qa.json').write_text(json.dumps(qa))
	result = organize(root)
	assert result['generated_png_count'] == 4
	assert result['selected_count'] == 3
	assert not (root / 'selected' / names['peak_abs']).exists()
	assert (root / 'all' / names['peak_abs']).exists()
	assert (root / 'logs' / 'sourcefind_target__BANE.log').exists()
	assert (root / 'catalog' / 'sourcefind_target__components_ascii.tab').exists()
	data = json.loads((root / 'image_qa.json').read_text())
	assert data['products'][0]['previews'][0]['file'].startswith('all/')
	assert data['products'][0]['source_finding']['catalogs']['components_ascii'].startswith('catalog/')
	assert data['imaging_families'][0]['name'] == 'test'


def test_none_profile(tmp_path):
	root = tmp_path / 'previews'
	full = root / 'all'
	full.mkdir(parents=True)
	(full / 'preview_a__overview.png').write_bytes(b'x')
	(full / 'image_qa.json').write_text(json.dumps({'products': []}))
	result = organize(root, profile='none')
	assert result['selected_count'] == 0
	assert (root / 'all' / 'preview_a__overview.png').exists()
