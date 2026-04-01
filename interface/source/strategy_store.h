#pragma once

#include <string>
#include <vector>

namespace StrategyStore {

const std::vector<std::string>& GetStrategyNames();
bool TryGetStrategyTemplate(const std::string& strategyName, std::string& outTemplate);

} // namespace StrategyStore
