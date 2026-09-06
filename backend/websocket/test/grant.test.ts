import test from 'node:test';
import assert from 'node:assert/strict';
import { callGrantAllows } from '../../api/src/callConference';
test('versioned grants fail closed without falling back to the original pair', () => {
  for (const grant of [{a:'A',b:'B',p:[],v:2}, {a:'A',b:'B',v:2}, {a:'A',b:'B',p:['A','B'],v:3}, {a:'A',b:'B',p:['A',4,'B'],v:2}]) {
    assert.equal(callGrantAllows(JSON.stringify(grant), 'A', 'B'), false);
  }
});
