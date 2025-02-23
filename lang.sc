// The language is top down by design
...<lib/model>..Point->Point // Import model without alias and ovveride internal point
...<lib/geometry>!{distance} // Import geometry but not distance
Engine -> <src/engine>.{Game : Element} // Import Game and Element only from engine and use Engine as suffix

// Add a Motor inside engine namespace
Engine -> Engine+{Motor -> //Motor impl}
// Remove Element from Engine
Engine -> Engine-{Element}

Color.$ -> u8.r : u8.g : u8.b : u8.a
Point.$ -> f32.x : f32.y
Point3D.$ -> f32.x??2 : f32.y??2 : f32.z??2
Point3Dv2.$ -> ...Point : f32.z

XYTuple..T.$ -> T.x : T.y : T.z
// Remove z from the tuple def
XYTuple..T.$ -> XYTuple..T.$-{z}

// Bottom stuff define as itself
Z -> Z
// x point to a literal
// a literal as explicit type it's meaning can vary
x -> 3
// Here we have the color full of 3
// It works because 3 is a compatible literal
Color.superColor -> x : x : x : x

XYTuple..T->f32.tupleOfF32 -> 2.0: 3.0
T.first..(XYTuple..T).tuple -> tuple.x
T.last..(XYTuple..T).tuple -> tuple.y

float -> f32 | f64
PointFloat -> Point.$ -> float.x : float.y

Point.2dOrigin
Poin3Dv2.3dOrigin

Origins -> Point3Dv2.3d -> 3dOrigin | Point.2d -> 2dOrigin
Origins.2d // Gives the default value of 2d with here is a immutable 2dOrigin
Color.r // Gives the default value for r which is 0 (unspecified)

RgbaColor -> u8.r : u8.g : u8.b : u8.a
RgbColor -> RgbaColor.{ r : g : b } // Selection def
RbgColor -> RgbaColor!{a} // Alternative remove def

RgbaColor.color -> u8.r->255 : u8.g->128 : u8.b->64 : u8.a->0

// Simple swizzle
RgbColor.swizzled -> color.{ r -> g : g -> b : b -> r }
  error{message->'u8 can only be between 0 and 255'}

// Simple enum
ColorMode -> Rgb | Rgba

// Dynamic swizzle function
Color.dynamicSwizzler..ColorMode.mode..Rgb.color -> mode ? {
    .Rgb  -> color.{ r -> g : g -> r : b }
    .Rgba -> color.{ r : g : b }
}

RgbColor.dynamicSwizzeld -> dynamicSwizzler..color..mode->ColorMode.Rgb


List..T -> None | (T : ...List..T)
NoneEmptyList..T -> T | (T : ...List..T)
Pair..A..B -> A : B
PairList..T -> List..T->Pair..A->T..B->T


// Defining a map to map t1 into t2
List..T2.map..List..T.x..T2.transform..T.e -> x ?
  {
    None -> None
    -> trnasform..e->x{%0} : map..x->x-{%0}..transform
  }

// Defining a fold to fold List..T into A
A.fold..List..T.x..A.acc..A.combine..A.acc..T.e -> x ? {
    None -> acc
    -> fold
        ..x->x-{%0}
        ..acc->(combine..e->x{%0}..acc)
        ..combine
}

List..u8.myList -> 22 : 45 : 22
u8.folded -> fold..x->myList
        ..acc->0
        ..(combine..u8.acc..u8.e-> acc + e)

Point2Dor3d -> Point | Point3D

// On peux matcher avec le symbole ?
f32.genericDistanceToOrigin..Point2Dor3d.p -> p ? {
    Point -> distance..p1->p..p2->(0:0)
    Point3D -> distance3D..p1->p..p2->(0:0:0)
}

// Imagine that BuildContext is defined somewhere
Widget.$ -> Widget.build..BuildContext.context
// Note that here the build is fixed in the def so it can be optimized
Rectangle.$ -> f32.width : f32.height
  : Widget..build->Widget.build..BuildContext.context
    -> Rectangle..width->3..height->4

// On imagine qu'il existe un fonction sqrt
// ICI par défaut on prends la distance a l'origine
f32.distance..Point.p1??(0:0)..Point.p2 -> {
    dx -> p2.x - p1.x
    dy -> p2.y - p1.y
    -> sqrt..x->dx * dx + dy * dy
}

Point.scale..Point.p..f32.factor -> p.x*factor : p.y*factor
Point.translate..Point.p..f32.shift -> p.x+shift : p.y*shift

f32.distanceTranslateScaled..Point.p1..Point.p2..f32.factor..f32.shift ->
      distance
        ..p1->(scale..p->(translate..p->p1..shift)..factor)
        ..p2->(scale..p->(translate..p->p2..shift)..factor)

PairListU8 -> List..T->Pair..A->u8..B->u8

f32.metricToOrigin..(f32.metric..Point.p1..Point.p2)..p -> metric..p1->(0:0)..p2->p
f32.distanceToOrigin -> metricToOrigin..metric->distance

u8.increment..u8.x -> x + 1

// Déclaration automatique de points
Point.myPoint  // ZII : myPoint est 0 : 0
Point3D.defaultPoint3D  // ZII : 2 : 2 : 2

// Point3D avec des valeurs modifiables a runtime
Point3D.anotherPoint ~> 2 : 2 : 2
Point3D.anotherPoint..z ~> 25..y->3  // y est fixé à 3, z est modifiabl

Point.p1 -> 1.0 : 2.0
Point.p2 -> 4.0 : 6.0
f32.distP1P2 -> distance..p1..p2
f32.distFromP2 -> distance..p2

Point.p3 -> 3.0 : 4.0
f32.distP1P3 -> distance..p1..p2->p3

f32.distToP1 -> distance..p1
f32.distToP3 -> distance..p1->p3

PairListU8.myPairList -> (10 : 20) : (30 : 40)

i32.intValue -> p1 ? {
  1.0 : 2.0 -> 1
  0 : 0 -> 2
  -> 3
}
