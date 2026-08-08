#pragma once

namespace fixture_index {

struct Derived {
  int ping() const;
};

int helper_ping(const Derived& value); // DECL:helper_ping helper_ping
int call_helper();
int delta_helper();

}  // namespace fixture_index
