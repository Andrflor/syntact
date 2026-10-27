package code_calc

// THE SCOPE OF A CLASS
//
// A computation is defined in a region: a parameter in the body of its loop, an arm
// and what it narrows in the arm, a match and a loop where they run, anything else
// where all it reads is. A law holds where both its sides are defined: in an arm
// where it narrowed n to 0, n is 0 — not elsewhere. A class is defined in the
// widest region one of its computations is, and its normal form is one of these:
// a use of the class, anywhere it is, reads it.

// scopes: the region each class is defined in, to a fixed point; NO_SCOPE for a
// class nothing defines.
scopes :: proc(g: ^Graph) -> []Maybe(Region) {
	out := make([]Maybe(Region), len(g.parent))
	for changed := true; changed; {
		changed = false
		for n, id in g.nodes {
			r, defined := node_scope(g, n, out)
			if !defined do continue
			c := find(g, g.home[id])
			if s, has := out[c].?; has && depth(g, s) <= depth(g, r) do continue
			out[c] = r
			changed = true
		}
	}
	return out
}

// node_scope: the region n is defined in, once its arguments are.
node_scope :: proc(g: ^Graph, n: Node, scope: []Maybe(Region)) -> (r: Region, defined: bool) {
	#partial switch n.kind {
	case .Param:
		return Region{.Body, n.owner, 0}, true
	case .Arm:
		return Region{.Arm, n.owner, n.index}, true
	case .Match:
		return g.matches[n.owner].parent, true
	case .Loop:
		return g.loops[n.owner].parent, true
	}
	r = ROOT
	for a in n.args do r = inner(g, r, scope[find(g, a)].? or_return)
	return r, true
}
