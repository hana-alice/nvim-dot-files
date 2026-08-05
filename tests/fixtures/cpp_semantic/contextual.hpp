#pragma once

struct OneTag {};
struct TwoTag {};

int dispatch(OneTag value);
int dispatch(TwoTag value);

#if SEMANTIC_USE_ONE
using ActiveTag = OneTag;
#else
using ActiveTag = TwoTag;
#endif

inline int call_contextual() {
  ActiveTag value;
  return dispatch(value); // QUERY:contextual_pick
}
