#include "api.hpp"

namespace fixture_index {

int delta_helper() {
  Derived value;
  return helper_ping(value); // QUERY:delta_helper helper_ping
}

}  // namespace fixture_index
