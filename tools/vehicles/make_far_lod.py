#!/usr/bin/env python3
"""
make_far_lod.py - builds light stand-ins of the car models for when they are far away.

    python3 tools/vehicles/make_far_lod.py

The Mercedes GLS has about 32,000 triangles and Godot's automatic simplification can only halve
it (the paint has too many hard edges), which is far too much for 50-odd parked cars on a phone.
This script snaps every vertex to a grid (vertex clustering), which keeps the silhouette but
drops the detail nobody sees past 30 m, and writes godot/assets/vehicles/<name>_far.glb: one mesh
("far"), so a distant car is a single draw call. Its vertex colour alpha says what each part is:
1 the body paint, 0.5 glass, 0 everything else (trim, tyres, lights).
Needs numpy.
"""
import json
import os
import struct
import numpy as np

DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'godot', 'assets', 'vehicles')
CELL = {'gls': 0.17, 'agera': 0.16}      # grid size in metres
GROUPS = {'paint': 'paint', 'glass': 'glass'}   # every other part goes to "dark"


def read_glb(path):
    f = open(path, 'rb').read()
    jl = struct.unpack('<I', f[12:16])[0]
    j = json.loads(f[20:20 + jl])
    bl = struct.unpack('<I', f[20 + jl:24 + jl])[0]
    b = f[28 + jl:28 + jl + bl]

    def acc(i):
        a = j['accessors'][i]
        bv = j['bufferViews'][a['bufferView']]
        n = {'SCALAR': 1, 'VEC2': 2, 'VEC3': 3, 'VEC4': 4}[a['type']]
        dt = {5126: np.float32, 5123: np.uint16, 5125: np.uint32, 5121: np.uint8}[a['componentType']]
        off = bv.get('byteOffset', 0) + a.get('byteOffset', 0)
        stride = bv.get('byteStride')
        if stride and stride != n * np.dtype(dt).itemsize:
            raw = np.frombuffer(b, np.uint8, a['count'] * stride, off).reshape(a['count'], stride)
            return raw[:, :n * np.dtype(dt).itemsize].copy().view(dt).reshape(a['count'], n)
        return np.frombuffer(b, dt, a['count'] * n, off).reshape(a['count'], n)

    parts = []
    for node in j['nodes']:
        if 'mesh' not in node:
            continue
        assert 'matrix' not in node and 'translation' not in node and 'rotation' not in node and 'scale' not in node
        for p in j['meshes'][node['mesh']]['primitives']:
            pos = acc(p['attributes']['POSITION']).astype(np.float64)
            idx = acc(p['indices']).reshape(-1, 3).astype(np.int64) if 'indices' in p else np.arange(len(pos)).reshape(-1, 3)
            parts.append((node.get('name', ''), pos, idx))
    return parts


def cluster(pos, idx, cell):
    key = np.floor(pos / cell).astype(np.int64)
    uniq, inv = np.unique(key, axis=0, return_inverse=True)
    inv = inv.reshape(-1)
    cnt = np.bincount(inv, minlength=len(uniq)).astype(np.float64)
    newpos = np.stack([np.bincount(inv, pos[:, k], len(uniq)) for k in range(3)], -1) / cnt[:, None]
    tri = inv[idx]
    ok = (tri[:, 0] != tri[:, 1]) & (tri[:, 1] != tri[:, 2]) & (tri[:, 0] != tri[:, 2])
    tri = tri[ok]
    # drop exact duplicates (same three corners, same winding)
    s = np.sort(tri, 1)
    _, first = np.unique((s * np.array([1, 1 << 20, 1 << 40])).sum(1), return_index=True)
    tri = tri[np.sort(first)]
    used = np.unique(tri)
    remap = -np.ones(len(newpos), np.int64)
    remap[used] = np.arange(len(used))
    return newpos[used], remap[tri]


def normals(pos, tri):
    fn = np.cross(pos[tri[:, 1]] - pos[tri[:, 0]], pos[tri[:, 2]] - pos[tri[:, 0]])
    vn = np.zeros_like(pos)
    for k in range(3):
        np.add.at(vn, tri[:, k], fn)
    ln = np.linalg.norm(vn, axis=1, keepdims=True)
    return vn / np.maximum(ln, 1e-12)


def write_glb(path, meshes):
    """meshes: list of (name, positions, triangles, colours or None); writes one node per mesh."""
    blob = b''
    j = {'asset': {'version': '2.0', 'generator': 'make_far_lod.py'}, 'scene': 0, 'scenes': [{'nodes': []}],
         'nodes': [], 'meshes': [], 'accessors': [], 'bufferViews': [], 'buffers': []}

    def add(arr, target, ctype, typ, minmax=False):
        nonlocal blob
        data = arr.tobytes()
        while len(blob) % 4:
            blob += b'\0'
        j['bufferViews'].append({'buffer': 0, 'byteOffset': len(blob), 'byteLength': len(data), 'target': target})
        blob += data
        a = {'bufferView': len(j['bufferViews']) - 1, 'componentType': ctype, 'count': len(arr), 'type': typ}
        if minmax:
            a['min'] = arr.min(0).tolist()
            a['max'] = arr.max(0).tolist()
        j['accessors'].append(a)
        return len(j['accessors']) - 1

    for name, pos, tri, col in meshes:
        p = add(pos.astype(np.float32), 34962, 5126, 'VEC3', True)
        n = add(normals(pos, tri).astype(np.float32), 34962, 5126, 'VEC3')
        attrs = {'POSITION': p, 'NORMAL': n}
        if col is not None:
            attrs['COLOR_0'] = add(col.astype(np.float32), 34962, 5126, 'VEC4')
        big = len(pos) > 65535
        i = add(tri.reshape(-1).astype(np.uint32 if big else np.uint16), 34963, 5125 if big else 5123, 'SCALAR')
        j['meshes'].append({'name': name, 'primitives': [{'attributes': attrs, 'indices': i}]})
        j['nodes'].append({'name': name, 'mesh': len(j['meshes']) - 1})
        j['scenes'][0]['nodes'].append(len(j['nodes']) - 1)
    while len(blob) % 4:
        blob += b'\0'
    j['buffers'].append({'byteLength': len(blob)})
    js = json.dumps(j, separators=(',', ':')).encode()
    while len(js) % 4:
        js += b' '
    out = struct.pack('<III', 0x46546C67, 2, 12 + 8 + len(js) + 8 + len(blob))
    out += struct.pack('<II', len(js), 0x4E4F534A) + js + struct.pack('<II', len(blob), 0x004E4942) + blob
    open(path, 'wb').write(out)


def main():
    for name, cell in CELL.items():
        src = os.path.join(DIR, name + '.glb')
        groups = {}
        for part, pos, idx in read_glb(src):
            g = GROUPS.get(part, 'dark')
            groups.setdefault(g, []).append((pos, idx))
        P, T, C = [], [], []
        total_in = 0
        base = 0
        for g in ('paint', 'glass', 'dark'):
            if g not in groups:
                continue
            pos = np.concatenate([p for p, _ in groups[g]])
            offs = np.cumsum([0] + [len(p) for p, _ in groups[g]])[:-1]
            idx = np.concatenate([i + o for (_, i), o in zip(groups[g], offs)])
            total_in += len(idx)
            p2, t2 = cluster(pos, idx, cell)
            P.append(p2)
            T.append(t2 + base)
            C.append(np.tile([1.0, 1.0, 1.0, {'paint': 1.0, 'glass': 0.5, 'dark': 0.0}[g]], (len(p2), 1)))
            base += len(p2)
        P, T = np.concatenate(P), np.concatenate(T)
        write_glb(os.path.join(DIR, name + '_far.glb'), [('far', P, T, np.concatenate(C))])
        total_out = len(T)
        print('%-6s %6d -> %5d triangles' % (name, total_in, total_out))


if __name__ == '__main__':
    main()
