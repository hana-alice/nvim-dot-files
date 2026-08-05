#include "direct.hpp"

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
  int result = zero(); // QUERY:zero
  result += with_default(3); // QUERY:default
  result += refpick(mutable_value); // QUERY:cvref_mutable
  result += refpick(const_value); // QUERY:cvref_const
  result += templated(mutable_value); // QUERY:template_nontemplate
  result += templated(another_value); // QUERY:template_generic
  result += adl_pick(token); // QUERY:adl
  result += derived.inherited(mutable_value); // QUERY:inherited
  return result;
}
