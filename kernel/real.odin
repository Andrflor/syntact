package kernel

import "core:fmt"
import "core:strings"

// REALS (specs/types.md §4.5: the reals are a field)
//
// A real written in the source is a decimal: a quotient of two integers, exactly.
// The reals computed from them by + - * / are quotients too: the field of the
// rationals, without rounding. A real is num / den, den > 0, in lowest terms; a
// result whose terms are beyond the integers written here is not computed.

real_of :: proc(num, den: i128) -> (r: Real, ok: bool) {
	if den == 0 || num == min(i128) || den == min(i128) do return
	n, d := num, den
	if d < 0 do n, d = -n, -d
	g := gcd(n, d)
	return Real{n / g, d / g}, true
}

real_int :: proc(v: i128) -> Real {
	return Real{v, 1}
}

real_is_zero :: proc(r: Real) -> bool {
	return r.num == 0
}

real_neg :: proc(r: Real) -> (Real, bool) {
	if r.num == min(i128) do return {}, false
	return Real{-r.num, r.den}, true
}

// real_add: a/b + c/d = (a * (d/g) + c * (b/g)) / (b/g * d), g = gcd(b, d).
real_add :: proc(x, y: Real) -> (r: Real, ok: bool) {
	g := gcd(x.den, y.den)
	a := mul_checked(x.num, y.den / g) or_return
	c := mul_checked(y.num, x.den / g) or_return
	n := add_checked(a, c) or_return
	d := mul_checked(x.den / g, y.den) or_return
	return real_of(n, d)
}

real_sub :: proc(x, y: Real) -> (r: Real, ok: bool) {
	n := real_neg(y) or_return
	return real_add(x, n)
}

// real_mul: (a/b) * (c/d), crossed reductions first.
real_mul :: proc(x, y: Real) -> (r: Real, ok: bool) {
	g1 := gcd(x.num, y.den)
	g2 := gcd(y.num, x.den)
	n := mul_checked(x.num / g1, y.num / g2) or_return
	d := mul_checked(x.den / g2, y.den / g1) or_return
	return real_of(n, d)
}

real_div :: proc(x, y: Real) -> (r: Real, ok: bool) {
	if y.num == 0 do return
	inverse := real_of(y.den, y.num) or_return
	return real_mul(x, inverse)
}

// real_compare: -1, 0 or 1, exactly: by the integer parts, then by the inverses of
// what is left (Euclid), without a product that could go beyond the integers.
real_compare :: proc(x, y: Real) -> int {
	a, b, c, d := x.num, x.den, y.num, y.den
	flip := 1
	for {
		qa, qc := floor_div(a, b), floor_div(c, d)
		if qa != qc do return flip * (qa < qc ? -1 : 1)
		ra, rc := a - qa * b, c - qc * d // 0 <= r < den
		if ra == 0 || rc == 0 {
			if ra == rc do return 0
			return flip * (ra == 0 ? -1 : 1)
		}
		// ra/b < rc/d  ⟺  b/ra > d/rc
		a, b, c, d = b, ra, d, rc
		flip = -flip
	}
}

real_less :: proc(x, y: Real) -> bool {
	return real_compare(x, y) < 0
}

// parse_real: a decimal literal, 12.5 or 1.5e3, as the quotient it writes.
parse_real :: proc(text: string) -> (r: Real, ok: bool) {
	mantissa, exponent := text, 0
	if i := strings.index_any(text, "eE"); i >= 0 {
		mantissa = text[:i]
		e := text[i + 1:]
		negative := false
		if len(e) > 0 && (e[0] == '-' || e[0] == '+') {
			negative = e[0] == '-'
			e = e[1:]
		}
		if len(e) == 0 do return
		for c in e {
			if c < '0' || c > '9' do return
			exponent = exponent * 10 + int(c - '0')
			if exponent > 60 do return
		}
		if negative do exponent = -exponent
	}
	num: i128 = 0
	den: i128 = 1
	fraction := false
	for c in mantissa {
		switch c {
		case '_':
		case '.':
			if fraction do return
			fraction = true
		case '0' ..= '9':
			num = mul_checked(num, 10) or_return
			num = add_checked(num, i128(c - '0')) or_return
			if fraction do den = mul_checked(den, 10) or_return
		case:
			return
		}
	}
	for _ in 0 ..< max(exponent, 0) do num = mul_checked(num, 10) or_return
	for _ in 0 ..< max(-exponent, 0) do den = mul_checked(den, 10) or_return
	return real_of(num, den)
}

// write_real: a decimal when the quotient has one, 0.5; otherwise the quotient,
// 1.0 / 3.0.
write_real :: proc(b: ^strings.Builder, r: Real) {
	d := r.den
	twos, fives := 0, 0
	for d % 2 == 0 {
		d /= 2
		twos += 1
	}
	for d % 5 == 0 {
		d /= 5
		fives += 1
	}
	if d != 1 {
		fmt.sbprintf(b, "%v.0 / %v.0", r.num, r.den)
		return
	}
	digits := max(twos, fives, 1)
	// num / den = num * 10^digits / den / 10^digits, an integer over 10^digits
	scaled, ok := mul_checked(r.num, pow10(digits) / r.den)
	if !ok || digits > 38 {
		fmt.sbprintf(b, "%v.0 / %v.0", r.num, r.den)
		return
	}
	negative := scaled < 0
	text := fmt.tprintf("%v", negative ? -scaled : scaled)
	for len(text) <= digits do text = strings.concatenate({"0", text}, context.temp_allocator)
	whole, fraction := text[:len(text) - digits], strings.trim_right(text[len(text) - digits:], "0")
	if fraction == "" do fraction = "0"
	fmt.sbprintf(b, "%s%s.%s", negative ? "-" : "", whole, fraction)
}

pow10 :: proc(n: int) -> i128 {
	out: i128 = 1
	for _ in 0 ..< n do out *= 10
	return out
}

// --- binary floating-point formats ---
//
// A format holds the reals m * 2^e, m an integer of at most `precision` bits, whose
// leading bit is at most at 2^max_exponent and whose last bit at least at
// 2^min_exponent, its subnormals included: dyadic rationals, F16 ⊂ F32 ⊂ F64 ⊂ the
// reals. ±∞ and NaN are not reals: no format holds them. A format is a set of
// reals, and what one of its values takes is in its type.

Real_Format :: enum u8 {
	Exact, // every real
	F16,
	F32,
	F64,
}

Format :: struct {
	precision, max_exponent, min_exponent: int,
	bits:                                  int, // what a value of the format takes
}

FORMATS := [Real_Format]Format {
	.Exact = {},
	.F16   = {11, 15, -24, 16},
	.F32   = {24, 127, -149, 32},
	.F64   = {53, 1023, -1074, 64},
}

// real_format: the format a range of the family f holds.
real_format :: proc(f: Range_Family) -> Real_Format {
	#partial switch f {
	case .F16:
		return .F16
	case .F32:
		return .F32
	case .F64:
		return .F64
	}
	return .Exact
}

// format_family: the family of a range of the format f.
format_family :: proc(f: Real_Format) -> Range_Family {
	switch f {
	case .F16:
		return .F16
	case .F32:
		return .F32
	case .F64:
		return .F64
	case .Exact:
	}
	return .Real
}

// holds_all: every real of the format narrow is in the format wide.
holds_all :: proc(wide, narrow: Real_Format) -> bool {
	return wide == .Exact || narrow != .Exact && wide >= narrow
}

// narrowest: the format of the reals both formats hold.
narrowest :: proc(a, b: Real_Format) -> Real_Format {
	if a == .Exact do return b
	if b == .Exact do return a
	return min(a, b)
}

// dyadic: r as m * 2^e, m odd, 0 as 0 * 2^0; false when its denominator is not a
// power of 2.
dyadic :: proc(r: Real) -> (m: i128, e: int, ok: bool) {
	if r.num == 0 do return 0, 0, true
	d := r.den
	for d % 2 == 0 {
		d /= 2
		e -= 1
	}
	if d != 1 do return
	m = r.num
	for m % 2 == 0 {
		m /= 2
		e += 1
	}
	return m, e, true
}

// representable: the format f holds r.
representable :: proc(r: Real, f: Real_Format) -> bool {
	if f == .Exact do return true
	m, e, dyadic_ok := dyadic(r)
	if !dyadic_ok do return false
	if m == 0 do return true
	n := bit_length(u128(abs(m)))
	format := FORMATS[f]
	return n <= format.precision && e >= format.min_exponent && e + n - 1 <= format.max_exponent
}

// Rounding: to the nearest value, the even one on a tie; toward +∞; toward -∞.
Rounding :: enum u8 {
	Nearest,
	Up,
	Down,
}

// round_real: the value of the format f nearest r, or the least at or above it, or
// the greatest at or below it; false when it is beyond the greatest finite value of
// f, or beyond the integers written here.
round_real :: proc(r: Real, f: Real_Format, mode := Rounding.Nearest) -> (out: Real, ok: bool) {
	if f == .Exact || r.num == 0 do return r, true
	format := FORMATS[f]
	negative := r.num < 0
	toward := mode // on |r|: up for a negative r is down on its magnitude
	if negative && mode == .Up do toward = .Down
	else if negative && mode == .Down do toward = .Up
	num, den := abs(r.num), r.den
	e := floor_log2(num, den)
	last := max(e - format.precision + 1, format.min_exponent) // the exponent of the last bit
	scaled := scale_pow2(Real{num, den}, -last) or_return // |r| / 2^last
	n := scaled.num / scaled.den
	rest := u128(scaled.num - n * scaled.den) // |r| / 2^last - n = rest / den
	switch toward {
	case .Nearest:
		twice := 2 * rest
		if twice > u128(scaled.den) || twice == u128(scaled.den) && n % 2 == 1 do n += 1
	case .Up:
		if rest != 0 do n += 1
	case .Down:
	}
	if n != 0 && bit_length(u128(n)) - 1 + last > format.max_exponent do return
	out = scale_pow2(Real{n, 1}, last) or_return
	if negative do out.num = -out.num
	return out, true
}

// next_above: the least value of the format f above r, a value of f; false beyond
// its greatest finite value, or beyond the integers written here.
next_above :: proc(r: Real, f: Real_Format) -> (out: Real, ok: bool) {
	format := FORMATS[f]
	if r.num == 0 do return scale_pow2(Real{1, 1}, format.min_exponent)
	num := abs(r.num)
	e := floor_log2(num, r.den)
	last := max(e - format.precision + 1, format.min_exponent)
	// below a power of 2, toward zero, the values are twice as close
	if r.num < 0 && at_least_pow2(r.den, num, -e) && last > format.min_exponent do last -= 1
	step := scale_pow2(Real{1, 1}, last) or_return
	out = real_add(r, step) or_return
	if !representable(out, f) do return {}, false
	return out, true
}

// floor_log2: the e with 2^e <= num / den < 2^(e+1), num, den > 0.
floor_log2 :: proc(num, den: i128) -> int {
	e := bit_length(u128(num)) - bit_length(u128(den))
	if !at_least_pow2(num, den, e) do e -= 1
	return e
}

// at_least_pow2: num / den >= 2^e, num, den > 0.
at_least_pow2 :: proc(num, den: i128, e: int) -> bool {
	if e >= 0 {
		if bit_length(u128(den)) + e > 127 do return false // den * 2^e is beyond num
		return num >= den << uint(e)
	}
	if bit_length(u128(num)) - e > 127 do return true // num * 2^-e is beyond den
	return num << uint(-e) >= den
}

// scale_pow2: r * 2^k; false beyond the integers written here.
scale_pow2 :: proc(r: Real, k: int) -> (out: Real, ok: bool) {
	num, den := r.num, r.den
	for _ in 0 ..< abs(k) {
		if k > 0 {
			if den % 2 == 0 do den /= 2
			else do num = mul_checked(num, 2) or_return
		} else {
			if num % 2 == 0 do num /= 2
			else do den = mul_checked(den, 2) or_return
		}
	}
	return real_of(num, den)
}

// bit_length: the bits of n, 0 for 0.
bit_length :: proc(n: u128) -> int {
	b := 0
	for x := n; x != 0; x >>= 1 do b += 1
	return b
}
