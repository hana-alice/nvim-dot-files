#pragma once

struct Widget {};
struct Another {};

#define FIXTURE_SCALE(value) ((value) * 2) // DEF:macro_scale

using WidgetAlias = Widget; // DEF:widget_alias

namespace fixture_alias_target { // DEF:namespace_target
extern int named_value;
}
namespace fixture_alias = fixture_alias_target; // DEF:namespace_alias

enum class Shade {
  Red = 3, // DEF:enum_red
  Blue,
};

struct Entity { // DEF:entity_type
  Entity(); // DECL:entity_ctor
  ~Entity(); // DECL:entity_dtor
  int operator+(int rhs) const; // DECL:entity_plus
  int field = 5; // DEF:entity_field
};

extern int global_value;

int pick(Widget value); // DECL:pick_widget
int pick(Another value);
int zero();
int with_default(int value, int scale = 2);
int refpick(Widget& value);
int refpick(const Widget& value);

template <typename T>
inline int identity(T value) {
  return 0;
}

template <>
inline int identity<Widget>(Widget value) { // DEF:identity_widget_specialization
  return 41;
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

struct VirtualBase {
  virtual int dyn_pick() const; // DECL:virtual_base
};

struct VirtualDerived final : VirtualBase {
  int dyn_pick() const override; // DECL:virtual_derived
};

inline int header_pick() {
  Widget value;
  return pick(value); // QUERY:header_pick
}
