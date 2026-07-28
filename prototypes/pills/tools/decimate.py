#!/usr/bin/env python3
"""OBJ -> vertex-clustered decimation -> base64 JS payload for the pill prototype.

Vertex clustering: snap verts to a uniform grid, merge each cell to its mean,
drop collapsed triangles. Crude but ideal for a mesh viewed at 30-120 px.
"""
import sys, base64, struct
import numpy as np

src, dst, res = sys.argv[1], sys.argv[2], int(sys.argv[3])

verts = []
faces = []
with open(src) as f:
    for line in f:
        if line.startswith('v '):
            parts = line.split()
            verts.append((float(parts[1]), float(parts[2]), float(parts[3])))
        elif line.startswith('f '):
            idx = [int(p.split('/')[0]) - 1 for p in line.split()[1:]]
            for k in range(1, len(idx) - 1):  # fan-triangulate
                faces.append((idx[0], idx[k], idx[k + 1]))

V = np.array(verts, dtype=np.float64)
F = np.array(faces, dtype=np.int64)
print(f"in: {len(V)} verts, {len(F)} tris")

lo, hi = V.min(0), V.max(0)
span = (hi - lo).max()
cell = np.floor((V - lo) / span * res).astype(np.int64)
key = cell[:, 0] * res * res + cell[:, 1] * res + cell[:, 2]
uniq, inverse = np.unique(key, return_inverse=True)

# mean position per cluster
NV = np.zeros((len(uniq), 3))
cnt = np.zeros(len(uniq))
np.add.at(NV, inverse, V)
np.add.at(cnt, inverse, 1)
NV /= cnt[:, None]

NF = inverse[F]
good = (NF[:, 0] != NF[:, 1]) & (NF[:, 1] != NF[:, 2]) & (NF[:, 0] != NF[:, 2])
NF = NF[good]
print(f"out: {len(NV)} verts, {len(NF)} tris")

# smooth normals: accumulate face normals
e1 = NV[NF[:, 1]] - NV[NF[:, 0]]
e2 = NV[NF[:, 2]] - NV[NF[:, 0]]
fn = np.cross(e1, e2)
N = np.zeros_like(NV)
for c in range(3):
    np.add.at(N, NF[:, c], fn)
lens = np.linalg.norm(N, axis=1, keepdims=True)
lens[lens == 0] = 1
N /= lens

# center + scale to unit box (renderer applies its own scale)
center = (NV.min(0) + NV.max(0)) / 2
NV = (NV - center) / ((NV.max(0) - NV.min(0)).max() / 2)

pos = NV.astype(np.float32).tobytes()
nrm = N.astype(np.float32).tobytes()
idx = NF.astype(np.uint32).tobytes()
blob = struct.pack('<II', len(NV), len(NF)) + pos + nrm + idx
b64 = base64.b64encode(blob).decode()
with open(dst, 'w') as f:
    f.write(f'window.SKULL_DATA="{b64}";\n')
print(f"payload: {len(blob)/1e6:.1f} MB binary, {len(b64)/1e6:.1f} MB base64 -> {dst}")
