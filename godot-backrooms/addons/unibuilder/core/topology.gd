@tool
class_name UBTopology
extends RefCounted
## Adjacency cache over a UBMeshData: edge -> bordering faces and vertex ->
## touching faces. Built lazily; rebuild after any topology mutation. Loop/ring
## selection, grow/shrink, bevel, and hole detection all query this.

## Vector2i(lo, hi) vertex-index pair -> Array of face indices.
var edge_faces: Dictionary = {}
## vertex index -> Array of face indices (plain Arrays: packed arrays are
## copy-on-write values and cannot be appended to in-place inside containers).
var vertex_faces: Array = []
## vertex index -> Array of Vector2i edge keys touching that vertex.
var vertex_edges: Array = []


## Cached build for read-only callers on the hot path (hover preselect rebuilds
## it per mouse-motion event). Valid only while `data.version` is unchanged,
## which every announced mutation bumps. Ops must keep using build(): they
## query topology while mutating, before the version bump lands, and would get
## a stale adjacency from the cache. The owner is held weakly so a closed
## scene's mesh is not kept resident.
static var _cache_owner: WeakRef = null
static var _cache_version := -1
static var _cache: UBTopology = null


static func build_cached(data: UBMeshData) -> UBTopology:
	if (
		_cache != null and _cache_owner != null
		and _cache_owner.get_ref() == data and data.version == _cache_version
	):
		return _cache
	_cache = build(data)
	_cache_owner = weakref(data)
	_cache_version = data.version
	return _cache


## Drop the cached adjacency. Called on scene change and plugin teardown.
static func clear_cache() -> void:
	_cache = null
	_cache_owner = null
	_cache_version = -1


static func build(data) -> UBTopology:
	var topo := UBTopology.new()
	var vertex_count: int = data.positions.size()
	topo.vertex_faces.resize(vertex_count)
	for vi in vertex_count:
		topo.vertex_faces[vi] = []
	for fi in data.faces.size():
		var verts: PackedInt32Array = data.faces[fi].vertices
		var n := verts.size()
		for i in n:
			var a := verts[i]
			var b := verts[(i + 1) % n]
			if a < 0 or a >= vertex_count or b < 0 or b >= vertex_count:
				continue
			topo.vertex_faces[a].append(fi)
			var key := Vector2i(mini(a, b), maxi(a, b))
			if not topo.edge_faces.has(key):
				topo.edge_faces[key] = []
			topo.edge_faces[key].append(fi)
	topo.vertex_edges.resize(vertex_count)
	for vi in vertex_count:
		topo.vertex_edges[vi] = []
	for key: Vector2i in topo.edge_faces:
		topo.vertex_edges[key.x].append(key)
		topo.vertex_edges[key.y].append(key)
	return topo
