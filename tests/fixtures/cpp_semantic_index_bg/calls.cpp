#include "api.hpp"

namespace fixture_index {

int call_helper() {
  Derived value;
  return helper_ping(value); // QUERY:call_helper helper_ping
}

}  // namespace fixture_index
