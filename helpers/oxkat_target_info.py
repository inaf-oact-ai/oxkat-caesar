"""Create a single-target private OXKAT project_info view for FLAG/2GC."""
import argparse
import json
from pathlib import PurePosixPath, Path


class TargetInfoError(ValueError):
	pass


def select_target(info, target):
	if not isinstance(info, dict) or not isinstance(target, str) or not target:
		raise TargetInfoError('Invalid metadata or target')
	keys = ('target_names', 'target_ids', 'target_ms', 'target_dirs', 'target_cal_map')
	if any(not isinstance(info.get(key), list) for key in keys):
		raise TargetInfoError('Missing target metadata lists')
	n = len(info['target_names'])
	if not n or any(len(info[key]) != n for key in keys):
		raise TargetInfoError('Inconsistent target metadata lengths')
	if len(set(info['target_names'])) != n or info['target_names'].count(target) != 1:
		raise TargetInfoError('Unknown or non-unique target')
	i = info['target_names'].index(target)
	ms_name = info['target_ms'][i]
	if (not isinstance(ms_name, str) or PurePosixPath(ms_name).name != ms_name
			or not ms_name.endswith('.ms') or ms_name in ('.', '..')):
		raise TargetInfoError('Invalid target Measurement Set name')
	secondaries = info.get('secondary_names')
	if not isinstance(secondaries, list) or info['target_cal_map'][i] not in secondaries:
		raise TargetInfoError('Invalid target-to-calibrator mapping')
	selected = dict(info)
	for key in keys:
		selected[key] = [info[key][i]]
	return selected, ms_name


def main():
	parser = argparse.ArgumentParser()
	parser.add_argument('--source', required=True)
	parser.add_argument('--output', required=True)
	parser.add_argument('--target', required=True)
	parser.add_argument('--expected-ms', required=True)
	args = parser.parse_args()
	with open(args.source, encoding='utf-8') as fh:
		info = json.load(fh)
	selected, ms_name = select_target(info, args.target)
	if ms_name != args.expected_ms:
		raise TargetInfoError('Selected target does not match expected MS')
	out = Path(args.output)
	with out.open('x', encoding='utf-8') as fh:
		json.dump(selected, fh, indent=2, sort_keys=True)
		fh.write('\n')
	print(ms_name)


if __name__ == '__main__':
	main()
