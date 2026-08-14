#include "api.hpp"

namespace fixture_index {

int Derived::ping() const { return 202; }
int helper_ping(const Derived& value) { return value.ping(); } // DEF:helper_ping helper_ping

}  // namespace fixture_index
