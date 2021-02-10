

function add_tint(t, tint, key)
  local tmp = {}
  if t == nil then
    return nil
  elseif type(t) == "table" then
    for _, v in pairs(t) do
      new = table.deepcopy(v)
      new["tint"] = tint
      table.insert(tmp, new)
    end
  else
    local item = {}
    item[key] = t
    item["tint"] = tint
    table.insert(tmp, item)
  end
  return tmp
end


function create_copy(from, name, tint)
  local copy = table.deepcopy(from)
  copy.name = name
  copy.icons = add_tint(from.icon, tint, "icon")
  return copy
end

-- Provider
provider_tint = {r=255, g=100, b=100}
local provider_entity = create_copy(data.raw["train-stop"]["train-stop"], "aps-provider-train-stop", provider_tint)
provider_entity.minable["result"] = "aps-provider-train-stop"

provider_entity.tint = provider_tint
provider_entity.color = {r=255, a=128}

for i,t in pairs({'animations', 'top_animations'}) do
  for i,d in pairs({'north', 'south', 'east', 'west'}) do
    provider_entity[t][d].layers[1].tint = provider_tint
    provider_entity[t][d].layers[1].hr_version.tint = provider_tint
  end
end
for i,d in pairs({'north', 'south', 'east', 'west'}) do
  provider_entity.rail_overlay_animations[d].tint = provider_tint
  provider_entity.rail_overlay_animations[d].hr_version.tint = provider_tint
end
-- error(serpent.block(provider_entity))

local provider_item = create_copy(data.raw["item"]["train-stop"], "aps-provider-train-stop", provider_tint)
provider_item.place_result = "aps-provider-train-stop"

local provider_recipe = create_copy(data.raw["recipe"]["train-stop"], "aps-provider-train-stop", provider_tint)
provider_recipe.enabled = true
provider_recipe.result = "aps-provider-train-stop"


-- Requester
requester_tint = {r=140, g=205, b=255}
local requester_entity = create_copy(data.raw["train-stop"]["train-stop"], "aps-requester-train-stop", requester_tint)
requester_entity.minable["result"] = "aps-requester-train-stop"

requester_entity.tint = requester_tint
requester_entity.color = {b=255, a=128}

for i,t in pairs({'animations', 'top_animations'}) do
  for i,d in pairs({'north', 'south', 'east', 'west'}) do
    requester_entity[t][d].layers[1].tint = requester_tint
    requester_entity[t][d].layers[1].hr_version.tint = requester_tint
  end
end
for i,d in pairs({'north', 'south', 'east', 'west'}) do
  requester_entity.rail_overlay_animations[d].tint = requester_tint
  requester_entity.rail_overlay_animations[d].hr_version.tint = requester_tint
end
-- error(serpent.block(requester_entity))

local requester_item = create_copy(data.raw["item"]["train-stop"], "aps-requester-train-stop", requester_tint)
requester_item.place_result = "aps-requester-train-stop"

local requester_recipe = create_copy(data.raw["recipe"]["train-stop"], "aps-requester-train-stop", requester_tint)
requester_recipe.enabled = true
requester_recipe.result = "aps-requester-train-stop"


data:extend{
  requester_item,
  requester_entity,
  requester_recipe,
  provider_item,
  provider_entity,
  provider_recipe
}

