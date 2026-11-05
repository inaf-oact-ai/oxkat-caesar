#!/usr/bin/env python3
"""Organize OXKAT preview outputs and select bounded REST-downloadable diagnostics.

Run after oxkat_preview.py --outdir RESULTS/previews/all. Nothing in IMAGES
is modified. No previously published QA or selected files are overwritten.
"""
import argparse
import json
import os
from pathlib import Path
import shutil

KINDS = {
	'mfs_restored_image': ('overview', 'center', 'peak_positive', 'peak_negative', 'brightest_source'),
	'mfs_primary_beam_corrected_image': ('overview', 'center', 'peak_positive'),
	'mfs_residual': ('overview', 'peak_positive', 'peak_negative'),
	'initial_cleaning_mask': ('overview',),
	'refined_cleaning_mask': ('overview',),
}
MAP_KINDS = ('overview',)


def _safe_file(name):
	if not isinstance(name, str) or not name or Path(name).name != name or name in ('.', '..'):
		raise ValueError('Unsafe generated filename')
	return name


def _move_items(src, dst, predicate):
	result = []
	for child in sorted(src.iterdir()):
		if child.is_symlink():
			raise ValueError('Symlink in generated preview directory')
		if not child.is_file() or not predicate(child.name):
			continue
		dest = dst / child.name
		if dest.exists() or dest.is_symlink():
			raise FileExistsError(str(dest))
		child.rename(dest)
		result.append(child.name)
	return result


def _rewrite_refs(node, moved, prefix='all'):
	"""Rewrite only recognized generated filenames, preserving all statistics."""
	if isinstance(node, dict):
		for key, value in list(node.items()):
			if key in ('file', 'bane', 'aegean') and isinstance(value, str) and value in moved:
				node[key] = moved[value]
			elif key == 'catalogs' and isinstance(value, dict):
				node[key] = {k: moved.get(v, v) if isinstance(v, str) else v for k, v in value.items()}
			else:
				_rewrite_refs(value, moved, prefix)
	elif isinstance(node, list):
		for item in node:
			_rewrite_refs(item, moved, prefix)


def _collect_selected(qa):
	chosen = set()
	for product in qa.get('products', []):
		kind = product.get('product_kind')
		wanted = KINDS.get(kind, ())
		for preview in product.get('previews', []):
			if preview.get('kind') in wanted:
				filename = preview.get('file')
				if isinstance(filename, str):
					chosen.add(Path(filename).name)
		sf = product.get('source_finding') or {}
		if sf.get('status') != 'complete':
			continue
		bright = sf.get('brightest_source_preview') or {}
		if bright.get('status') == 'complete' and bright.get('file'):
			chosen.add(Path(bright['file']).name)
		for key in ('background', 'rms'):
			diagnostics = sf.get(key) or {}
			for item in diagnostics.get('previews', []):
				if item.get('kind') in MAP_KINDS and item.get('file'):
					chosen.add(Path(item['file']).name)
	return chosen


def organize(root, profile='selected'):
	"""Move files, retain complete QA and create selected PNGs for REST indexing.

	root is results/previews, with all/ populated by the scientific generator.
	"""
	if profile not in ('none', 'selected', 'all'):
		raise ValueError('Unsupported preview retention profile')
	root = Path(root).absolute()
	full = root / 'all'
	if not full.is_dir() or full.is_symlink() or root.is_symlink():
		raise ValueError('Missing safe previews/all directory')
	qa_source = full / 'image_qa.json'
	if not qa_source.is_file() or qa_source.is_symlink():
		raise ValueError('Missing image_qa.json in previews/all')
	destination_qa = root / 'image_qa.json'
	if destination_qa.exists() or destination_qa.is_symlink():
		raise FileExistsError('Refusing to replace existing image_qa.json')
	# Read and validate QA before moving scientific diagnostics.
	qa = json.loads(qa_source.read_text(encoding='utf-8'))
	if not isinstance(qa, dict) or not isinstance(qa.get('products'), list):
		raise ValueError('Invalid image_qa.json')
	logs = root / 'logs'
	catalogs = root / 'catalog'
	selected = root / 'selected'
	for directory in (logs, catalogs, selected):
		if directory.is_symlink():
			raise ValueError('Unsafe output directory')
		directory.mkdir(exist_ok=True)
	logfiles = _move_items(full, logs, lambda n: n.startswith('sourcefind_') and n.endswith('.log'))
	catfiles = _move_items(full, catalogs, lambda n: n.startswith('sourcefind_') and n.endswith(('.dat', '.tab', '.reg', '.fits', '.csv')))
	referenced = {n: 'logs/' + n for n in logfiles}
	referenced.update({n: 'catalog/' + n for n in catfiles})
	for child in full.iterdir():
		if child.is_symlink():
			raise ValueError('Symlink in previews/all')
		if child.is_file() and child.suffix == '.png':
			referenced[child.name] = 'all/' + child.name
	_rewrite_refs(qa, referenced)
	wanted = _collect_selected(qa) if profile == 'selected' else set()
	if profile == 'all':
		wanted = {p.name for p in full.glob('preview_*.png') if p.is_file() and not p.is_symlink()}
	retained = []
	for name in sorted(wanted):
		_safe_file(name)
		origin = full / name
		if not origin.is_file() or origin.is_symlink():
			continue
		dest = selected / name
		if dest.exists() or dest.is_symlink():
			raise FileExistsError(str(dest))
		# Copies avoid link semantics across retention, archives and filesystems.
		with origin.open('rb') as reader, dest.open('xb') as writer:
			shutil.copyfileobj(reader, writer, 1024 * 1024)
		retained.append('selected/' + name)
	qa['preview_storage'] = {
		'layout_version': 1,
		'generated_directory': 'all',
		'selected_directory': 'selected',
		'catalog_directory': 'catalog',
		'logs_directory': 'logs',
		'retention_profile': profile,
		'selected_files': retained,
		'selected_count': len(retained),
		'generated_png_count': sum(1 for f in full.iterdir() if f.is_file() and f.suffix == '.png'),
		'catalog_files': ['catalog/' + n for n in catfiles],
		'log_files': ['logs/' + n for n in logfiles],
	}
	# Only selected_files refer to items eligible for individual REST retention.
	with destination_qa.open('x', encoding='utf-8') as stream:
		json.dump(qa, stream, indent=2, allow_nan=False)
		stream.write('\n')
	qa_source.unlink()
	return qa['preview_storage']


def main():
	parser = argparse.ArgumentParser(description=__doc__)
	parser.add_argument('--previews', required=True)
	parser.add_argument('--retention-profile', choices=('none', 'selected', 'all'), default='selected')
	args = parser.parse_args()
	result = organize(args.previews, args.retention_profile)
	print('OXKAT preview layout: %d generated PNGs, %d selected, %d catalogs, %d logs' %
          (result['generated_png_count'], result['selected_count'], len(result['catalog_files']), len(result['log_files'])), flush=True)

if __name__ == '__main__':
	main()
