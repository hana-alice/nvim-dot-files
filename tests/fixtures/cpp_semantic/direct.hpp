#pragma once

struct Widget {};
struct Another {};

int pick(Widget value);
int pick(Another value);
int zero();
int with_default(int value, int scale = 2);
int refpick(Widget& value);
int refpick(const Widget& value);

template <typename T>
inline int identity(T value) {
  return 0;
}

template <typename T>
inline int templated(T value) { // DEF:templated_generic
  return identity(value);
}

int templated(Widget value);

namespace fixture_adl {
struct Token {};
int adl_pick(Token value);
}

struct Base {
  int inherited(Widget value) const;
};

struct Derived : Base {};

inline int header_pick() {
  Widget value;
  return pick(value); // QUERY:header_pick
}
