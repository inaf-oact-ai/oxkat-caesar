"""Read-only, lightweight OXKAT target identity check for a staged MS."""
import argparse
import json
from pathlib import Path


class MSIdentityError(ValueError):
	pass


def verify(ms_path, project_info_path, target, table_factory=None):
	ms = Path(ms_path)
	if not ms.is_dir() or ms.is_symlink():
		raise MSIdentityError('Staged Measurement Set is not a real directory')
	with open(project_info_path, encoding='utf-8') as stream:
		info = json.load(stream)
	if not isinstance(info, dict):
		raise MSIdentityError('Invalid project metadata')
	if info.get('target_names') != [target]:
		raise MSIdentityError('Selected target does not match project metadata')
	ms_names = info.get('target_ms')
	if not isinstance(ms_names, list) or len(ms_names) != 1:
		raise MSIdentityError('Expected one target MS in project metadata')
	if not isinstance(ms_names[0], str) or not ms_names[0].endswith('.ms'):
		raise MSIdentityError('Invalid MS name in project metadata')
	if table_factory is None:
		from pyrap.tables import table as table_factory
	field_dir = ms / 'FIELD'
	if not field_dir.is_dir() or field_dir.is_symlink():
		raise MSIdentityError('Measurement Set FIELD table missing')
	field_table = table_factory(str(field_dir), readonly=True, ack=False)
	try:
		names = [str(x) for x in field_table.getcol('NAME')]
	finally:
		field_table.close()
	if target not in names:
		raise MSIdentityError('Selected target is absent from MS FIELD table')
	return names


def main():
	parser = argparse.ArgumentParser()
	parser.add_argument('--ms', required=True)
	parser.add_argument('--project-info', required=True)
	parser.add_argument('--target', required=True)
	args = parser.parse_args()
	try:
		names = verify(args.ms, args.project_info, args.target)
	except (MSIdentityError, OSError, ValueError) as exc:
		parser.exit(2, 'ERROR: MS identity verification failed: %s\n' % exc)
	print('INFO: MS FIELD table contains target %s (%d fields)' % (args.target, len(names)))


if __name__ == '__main__':
	main()
