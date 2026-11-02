"""No casacore install or real Measurement Set required."""
import json
import pytest
from oxkat_ms_identity import verify, MSIdentityError


class FieldTable:
	def __init__(self, names):
		self.names = names
	def getcol(self, name):
		assert name == 'NAME'
		return self.names
	def close(self):
		pass


def prepare(tmp_path):
	ms = tmp_path / 'input' / 'target_ms'
	(ms / 'FIELD').mkdir(parents=True)
	meta = tmp_path / 'project_info.json'
	meta.write_text(json.dumps({'target_names': ['MAXIJ1348'], 'target_ms': ['measurement_set_1024ch_MAXIJ1348.ms']}))
	return ms, meta


def test_accepts_target_present_in_field_table(tmp_path):
	ms, meta = prepare(tmp_path)
	assert verify(ms, meta, 'MAXIJ1348', lambda *a, **kw: FieldTable(['MAXIJ1348', 'J1744-5144'])) == ['MAXIJ1348', 'J1744-5144']


def test_rejects_wrong_scientific_field(tmp_path):
	ms, meta = prepare(tmp_path)
	with pytest.raises(MSIdentityError, match='absent'):
		verify(ms, meta, 'MAXIJ1348', lambda *a, **kw: FieldTable(['EXO1846-031']))


def test_rejects_wrong_project_metadata(tmp_path):
	ms, meta = prepare(tmp_path)
	with pytest.raises(MSIdentityError, match='metadata'):
		verify(ms, meta, 'EXO1846-031', lambda *a, **kw: FieldTable(['EXO1846-031']))
