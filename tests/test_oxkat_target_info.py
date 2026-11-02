import copy
import pytest
from oxkat_target_info import select_target, TargetInfoError


@pytest.fixture
def info():
	return {
		'band': 'L',
		'target_names': ['MAXIJ1348', 'EXO1846-031'],
		'target_ids': ['1', '6'],
		'target_ms': ['measurement_set_1024ch_MAXIJ1348.ms', 'measurement_set_1024ch_EXO1846-031.ms'],
		'target_dirs': [[1., 2.], [3., 4.]],
		'target_cal_map': ['J1744-5144', 'J1911-2006'],
		'secondary_names': ['J1744-5144', 'J1911-2006'],
	}


def test_target_projection_preserves_parent(info):
	original = copy.deepcopy(info)
	projected, ms_name = select_target(info, 'MAXIJ1348')
	assert projected['target_names'] == ['MAXIJ1348']
	assert projected['target_cal_map'] == ['J1744-5144']
	assert projected['target_ms'] == [ms_name]
	assert projected['secondary_names'] == info['secondary_names']
	assert info == original


def test_invalid_target(info):
	with pytest.raises(TargetInfoError):
		select_target(info, 'UNKNOWN')


def test_inconsistent_lists(info):
	info['target_ids'] = ['1']
	with pytest.raises(TargetInfoError):
		select_target(info, 'MAXIJ1348')


def test_invalid_calibrator(info):
	info['target_cal_map'][0] = 'UNKNOWN'
	with pytest.raises(TargetInfoError):
		select_target(info, 'MAXIJ1348')
