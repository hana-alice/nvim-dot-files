#include "direct.hpp"

namespace fixture_alias_target {
int named_value = 7; // DEF:named_value
}

int global_value = 9; // DEF:global_value

Entity::Entity() = default; // DEF:entity_ctor
Entity::~Entity() = default; // DEF:entity_dtor
int Entity::operator+(int rhs) const { // DEF:entity_plus
  return field + rhs;
}

int pick(Widget value) {
  return 11;
}

int pick(Another value) {
  return 22;
}

int zero() { // DEF:zero
  return 0;
}

int with_default(int value, int scale) { // DEF:with_default
  return value * scale;
}

int refpick(Widget& value) { // DEF:refpick_mutable
  return identity(value);
}

int refpick(const Widget& value) { // DEF:refpick_const
  return identity(value);
}

int templated(Widget value) { // DEF:templated_widget
  return identity(value);
}

namespace fixture_adl {
int adl_pick(Token value) { // DEF:adl_pick
  return identity(value);
}
}

int Base::inherited(Widget value) const { // DEF:inherited
  return identity(value);
}

int VirtualBase::dyn_pick() const { // DEF:virtual_base
  return 31;
}

int VirtualDerived::dyn_pick() const { // DEF:virtual_derived
  return 32;
}

int source_pick() {
  Widget value;
  return pick(value); // QUERY:source_pick
}

int source_language_rules() {
  Widget mutable_value;
  const Widget const_value;
  Another another_value;
  fixture_adl::Token token;
  Derived derived;
  VirtualDerived derived_virtual;
  VirtualBase& base_virtual = derived_virtual;
  int result = zero(); // QUERY:zero
  result += with_default(3); // QUERY:default
  result += refpick(mutable_value); // QUERY:cvref_mutable
  result += refpick(const_value); // QUERY:cvref_const
  result += templated(mutable_value); // QUERY:template_nontemplate
  result += templated(another_value); // QUERY:template_generic
  result += adl_pick(token); // QUERY:adl
  result += derived.inherited(mutable_value); // QUERY:inherited
  result += derived_virtual.dyn_pick(); // QUERY:virtual_derived_static
  result += base_virtual.dyn_pick(); // QUERY:virtual_base_static
  WidgetAlias alias_value; // QUERY:type_alias
  auto entity = Entity(); // QUERY:constructor
  result += entity.field; // QUERY:field
  result += global_value; // QUERY:variable
  result += static_cast<int>(Shade::Red); // QUERY:enum_member
  result += fixture_alias::named_value; // QUERY:namespace_alias
  result += FIXTURE_SCALE(2); // QUERY:macro
  result += identity(alias_value); // QUERY:template_specialization
  result += entity + 3; // QUERY:operator
  entity.~Entity(); // QUERY:destructor
  return result;
}
