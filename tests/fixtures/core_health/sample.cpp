#include <string_view>

namespace health_fixture {
class Greeter {
 public:
  constexpr std::string_view message() const { return "healthy"; }
};
}  // namespace health_fixture

int main() {
  return health_fixture::Greeter{}.message() == "healthy" ? 0 : 1;
}
