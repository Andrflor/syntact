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
