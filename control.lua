
ITEM_TIMEOUT = 300 * 60 -- 5 minutes

INSERTER_DIRECTION = {
  ['pickup_position'] = 'drop_target',
  ['drop_position'] = 'pickup_target'
}

INSERTER_FORCE_STACK_BONUS = {
  ['stack-filter-inserter'] = 'stack_inserter_capacity_bonus',
  ['filter-inserter'] = 'inserter_stack_size_bonus'
}


function for_each_station(func)
  for _, force in pairs(game.forces) do
    for _, stop in pairs(force.get_train_stops()) do
      if stop.name == 'aps-provider-train-stop' or stop.name == 'aps-requester-train-stop' then
        func(stop)
      end
    end
  end
end

function print_stop(stop)
  log_message("Found stop: "..stop.backer_name.." which is of type "..stop.name)
end

function update_station_name(stop, prefix, positive)
  local name = prefix
  if signals == nil then
    signals = {}
  end

  if not global.station_resources then
    global.station_resources = {}
  end
  if not global.station_resources[stop.unit_number] then
    global.station_resources[stop.unit_number] = {}
  end
  history = global.station_resources[stop.unit_number]

  for _,s in pairs(global.resources[stop.unit_number].signals) do
    if s.signal.type ~= 'virtual' then
      if (positive and s.count >= 0) or (not positive and s.count < 0) then
        key = "[img="..s.signal.type.."."..s.signal.name.."]"
        if not history[key] then
          history[key] = { signal=s.signal }
        end
        history[key].ttl = game.tick + ITEM_TIMEOUT
      end
    end
  end

  items = {}
  for key, meta in pairs(history) do
    if game.tick > meta.ttl then
      game.print("Item "..key.." vanished from station "..stop.backer_name)
      history[key] = nil
    else
      items[#items+1] = key
    end
  end

  table.sort(items)
  name = name .. table.concat(items)

  if stop.backer_name ~= name then
    stop.backer_name = name
  end
end

function update_inserter(event, job, inserter_id, meta)
  stop = job.stop
  train = job.train
  inserter = meta.inserter

  if not inserter.valid then
    job.inserters.count = delivery.job.count - 1
    job.inserters.list[inserter_id] = nil
    return
  end

  --[[log = function(message)
    log_message("["..event.tick.."] STOP "..stop.unit_number..": "..message)
  end ]]--

  --log("Inserter #"..inserter_id)

  local held = inserter.held_stack
  if held and held.valid_for_read then
    if not job.signals.dest[held.name] then
      job.signals.dest[held.name] = { signal={name=held.name,type=held.type}, count=held.count }
    else
      job.signals.dest[held.name].count = job.signals.dest[held.name].count + held.count
    end
    --log("Holding "..held.count.." of "..held.name)
  else
    held = nil
  end

  game.print("SSS: "..serpent.line(job.signals))
  --log("SIGNALS: "..serpent.block(job.signals))
  while true do
    request_item = job.signals.request_index[job.current]
    if not request_item then
      game.print("No more requests")
      --log("There are no more requests to process")
      needed = -1
      break
    else
      game.print("RI is "..(request_item or 'nil'))
      request = job.signals.request[request_item]
      game.print("Request is "..serpent.block(request))
      available = (job.signals.source[request_item] or {count=0}).count
      stock = (job.signals.dest[request_item] or {count=0}).count + request.pending
      needed = request.count - stock

      filter = request_item
      stack = meta.max_stack

      game.print("Current request is for "..request.count.." of "..request_item..". "..needed.." more needed, "..available.." available in source")
    end

    if available > 0 and needed > 0 then
      break
    else
      job.current = job.current + 1
    end
  end

  --log(serpent.block(meta))
  if needed > meta.max_stack then
    -- we can expect to delivery a full stack and that will be okay
    --log("Plan: deliver "..stack.." of "..filter)
    request.pending = request.pending + stack
  elseif needed > 0 then
    -- we can delivery some, but this is the last planned delivery for this good
    stack = needed
    --log("Plan: deliver "..stack.." of "..filter.." and move to the next request")
    request.pending = request.pending + stack
  else
    -- we will not deliver anything. Switch off
    filter = nil
    stack = 0
    --log("Plan: Shut down this inserter")
  end

  if job.inserters.list[inserter_id].filter ~= filter then
    inserter.set_filter(1,filter)
    job.inserters.list[inserter_id].filter = filter
    --log("set inserter "..inserter_id.." to filter "..(filter or 'nil'))
  end

  if job.inserters.list[inserter_id].stack ~= stack then
    inserter.inserter_stack_size_override = stack
    job.inserters.list[inserter_id].stack = stack
    --log("set inserter "..inserter_id.." to stack size "..stack)
  end
end

function delivery_tick(event)
  for stop_id, delivery in pairs(global.deliveries_in_progress or {}) do
    stop = delivery.stop
    train = delivery.train

    if not stop.valid then return end
    if not train.valid then return end

    delivery.signals, request_count = update_stop_signals(stop, train, delivery)

    --log("BEGIN - check inserters")

    delivery.current = 1
    delivery.request_count = request_count

    for id, i in pairs(delivery.inserters.list) do
      update_inserter(event, delivery, id, i)
    end

    --log("END")
  end
end

function log_message(message)
  game.write_file('aps.log', message.."\n", true)
end

function update_jobs(stop, trains)
  train = stop.get_stopped_train()
  if not stop.name == 'aps-requester-train-stop' then
    return
  end

  signals, request_count = update_stop_signals(stop, train)
  global.stop_signals[stop.unit_number] = signals

  if request_count > 0 then
    job_id = stop.unit_number

    -- We have a request. Is it recorded?
    if not global.jobs[job_id] then
      global.jobs[job_id] = {wanted=signals.request, stop=stop}
    end
    job = global.jobs[job_id]
    job.stop = stop


    -- Is the request currently met?
    met = 0
    for item, request in pairs(job.wanted) do
      if signals.dest[item] and signals.dest[item].count >= request.count then
        met = met + 1
      end
    end

    if met == request_count then
      --game.print("Stop "..stop.backer_name.." has met all requests this tick")
      -- Clear train state
      if job.train then
        jbt = global.job_by_train[job.train.id]
        --if jbt.state == JBT_STATE.arrived then
          --game.print("Clear jbt/train")
          global.job_by_train[job.train.id] = nil
          job.train = nil
          for item, meta in pairs(job.wanted) do
           job.source.promised[item] = 0 -- (job.source.promised[item] or 0) - meta.count
          end
        --end
      end
      return
    end

    -- Is the train actually delivering now?
    if train and job.train == train then
      update_jobs_delivery(stop, train)
      return
    end

    -- Is there a train picking up
    if job.train then
      -- Don't care if it's not at a station
      if not job.train.station then return end
      -- Don't care if it's not at the *right* station
      if not job.train.station == job.source.stop then return end
      update_jobs_pickup(job.source.stop, job.train, job)
    end

    -- Is there a train on the way?
    -- Okay, we don't have a delivery yet.
    for i, train in pairs(trains) do
      if train.station and train.station.backer_name == 'DEPOT' then
        -- This is a valid train for us

        -- Find a provider station
        for stop_id, resources in pairs(global.resources) do
          if resources.type == 'aps-provider-train-stop' then
            if check_stop_resources(resources, job) then
              -- train.schedule = generate_train_schedule(job, selected)
              job.train = train
              job.source = resources
              global.job_by_train[train.id] = {job=job, state=JBT_STATE.collecting}
              trains[i] = nil -- Remove this train from the tick stack

              for item, meta in pairs(job.wanted) do
                resources.promised[item] = (resources.promised[item] or 0) + meta.count
              end

              train.schedule = generate_train_schedule(train, job, resources)
              break
            end
          end
        end
        break
      else
        -- Ignore this train, and don't process it again this tick
        trains[i] = nil
      end
    end
  end
end

function check_stop_resources(resources, job)

  goods = {}
  for _,i in pairs(resources.signals) do
    goods[i.signal.name] = i.count - (resources.promised[i.signal.name] or 0)
  end


  for item, meta in pairs(job.wanted) do
    if not goods[item] then
      return false
    end

    if goods[item] < meta.count then
      return false
    end

  end

  return true
end

function update_jobs_pickup(stop, train, job)
  pickup = {}
  pickup.signals = global.stop_signals[stop.unit_number]
  pickup.active_item = nil

  pickup.stop = stop
  pickup.train = train
  pickup.direction = 'dest'
  pickup.job = job
  pickup.inserters = get_filter_inserters(train, 'drop_position')

  global.deliveries_in_progress[stop.unit_number] = pickup
end

function update_jobs_delivery(stop, train)
  delivery = {}
  delivery.signals = global.stop_signals[stop.unit_number]
  delivery.active_item = nil

  delivery.stop = stop
  delivery.train = train
  pickup.direction = 'source'
  delivery.inserters = get_filter_inserters(train, 'pickup_position')

  global.deliveries_in_progress[stop.unit_number] = delivery
end

function update_stop_signals(stop, train, delivery)
  if delivery and delivery.direction == 'source' then
    chests = 'dest'
    wagons = 'source'
  else
    chests = 'source'
    wagons = 'dest'
  end
  train_key = chests

  local circuits = stop.circuit_connection_definitions
  signals = {
    ['request'] = {},
    ['dest'] = {},
    ['source'] = {},
    ['request_index'] = {}
  }

  requests = 0
  behaviour = stop.get_or_create_control_behavior()

  if train then
    for s, c in pairs(train.get_contents()) do
      signals[train_key][s] = {signal={name=s,type='item'}, count=c}
    end
    for _,s in pairs(train.get_fluid_contents()) do
      signals[train_key][s] = {signal={name=s,type='fluid'}, count=c}
    end
  end

  -- log_message("T: "..serpent.line(signals.train))
  for _, c in pairs(circuits) do
    for _,s in pairs(stop.get_circuit_network(c.wire).signals or {}) do
      if s.signal.type ~= 'virtual' then
        local count = s.count
        if behaviour.read_from_train and signals[train_key][s.signal.name] then
          count = count - signals[train_key][s.signal.name].count
        end
        -- log_message("W:"..c.wire..",S:"..s.signal.name..",C:"..count)
        if count >= 0 then
          signals[chests][s.signal.name] = {signal=s.signal,count=count}
        elseif train_key == 'dest' then
          signals.request[s.signal.name] = {signal=s.signal,count=math.abs(count),pending=0}
          requests = requests + 1
          signals.request_index[requests] = s.signal.name
        end
      end
    end
  end

  if delivery and delivery.job and train_key == 'source' then
    game.print(serpent.line(delivery))
    for item,meta in pairs(delivery.job.wanted) do
      signals.request[s.signal.name] = {signal=meta.signal,count=meta.count,pending=0}
      requests = requests + 1
      signals.request_index[requests] = item
    end
  end

  return signals, requests
end

function get_rolling_stock(train)
  local stock = {}
  for _,c in pairs(train.cargo_wagons) do
    table.insert(stock, c)
  end

  return stock
end
function get_filter_inserters(train, target)
  inserters = {}
  local count = 0
  local surface = train.station.surface

  for _,w in pairs(get_rolling_stock(train)) do
    for _,e in pairs(surface.find_entities_filtered{position=w.position,radius=3, type='inserter'}) do
      if string.find(e.name, 'filter') then
        local other_end = e[INSERTER_DIRECTION[target]]
        if other_end then
          for _, c in pairs(surface.find_entities_filtered{position=e[target]}) do
            if c == w then
              -- This is a filter inserter that targets our wagon
              max_stack = global.max_stack[e.force.index][e.name]
              inserters[e.unit_number] = {inserter=e, filter=e.get_filter(1), stack=e.inserter_stack_size_override, max_stack=max_stack}
              count = count + 1
              -- Make sure the filter is in whitelist mode
              e.inserter_filter_mode = 'whitelist'
              --log_message(serpent.line(inserters[e.unit_number]))
            end
          end
        end
      end
    end
  end
  return {count=count, list=inserters}
end

-- function interval_60s(event)
-- end

function interval_10s(event)
  -- Check for timeouts
  for_each_station(
    function(stop)
    end
  )
end

function generate_train_schedule(train, job, provider)
  local records = {}
  local schedule = {
    current = 1,
    records = records
  }

  -- first, go to the pickup point
  table.insert(records, {rail=provider.stop.connected_rail, temporary=true})

  -- Next, pick up the goods
  local pickup_conditions = {}
  for item, meta in pairs(job.wanted) do
    table.insert(pickup_conditions,
      {
        type="item_count",
        compare_type="and",
        condition={
          comparator="≥",
          first_signal=meta.signal,
          constant=meta.count
        }
      }
    )
  end
  table.insert(records, {station=provider.stop.backer_name, wait_conditions=pickup_conditions, temporary=true})

  -- Now, move to the request stop
  table.insert(records, {rail=job.stop.connected_rail, temporary=true})

  -- And deliver
  table.insert(records, {station=job.stop.backer_name, wait_conditions={{type="empty", compare_type="and"}}, temporary=true})

  -- Then back to the depot
  table.insert(records, {station='DEPOT', wait_conditions={{type="inactivity", ticks=300, compare_type="and"}}})

  return schedule
end

function interval_1s(event)
  if global.jobs == nil then global.jobs = {} end
  if global.trains == nil then global.trains = {} end
  if global.job_by_train == nil then global.job_by_train = {} end
  if global.resources == nil then global.resources = {} end

  -- Clear our delivery data. It will be regenerated.
  global.deliveries_in_progress = {}
  global.stop_signals = {}
  global.max_stack = {}
  global.train_cache = {}

  -- Get inserter capacity
  for _, force in pairs(game.forces) do
    global.max_stack[force.index] = {}
    for name, key in pairs(INSERTER_FORCE_STACK_BONUS) do
      max = 1 + force[key or 'inserter_stack_size_bonus']
      global.max_stack[force.index][name] = max
    end
  end

  for_each_station(
    function(stop, force)
      local surface = stop.surface
      local force = stop.force

      if not global.train_cache[surface.name] then
        global.train_cache[surface.name] = {}
      end
      if not global.train_cache[surface.name][force.name] then
        global.train_cache[surface.name][force.name] = surface.get_trains(force)
      end

      local trains = global.train_cache[surface.name][force.name]
      local signals = stop.get_merged_signals() or {}
      if not global.resources[stop.unit_number] then
        global.resources[stop.unit_number] = {type=stop.name, signals==nil, promised={}, stop=stop}
      end
      global.resources[stop.unit_number].signals = signals

      if stop.name == 'aps-provider-train-stop' then
        update_station_name(stop, 'SOURCE: ', true)
      else
        update_station_name(stop, 'SINK: ', false)
      end

      update_jobs(stop, trains)
    end
  )
end

JBT_STATE_VAL = { 'collecting', 'loading', 'hauling', 'arrived' }
JBT_STATE = { collecting=1, loading=2, hauling=3, arrived=4 }
function train_changed_state(event)
  train = event.train
  jbt = global.job_by_train[train.id]
  if not jbt then
    return
  end

  if jbt.state == JBT_STATE.collecting then
    if train.state == defines.train_state.wait_station and train.station ~= nil then
      if train.station == jbt.job.source.stop then
        jbt.state = JBT_STATE.loading
      end
    end
  elseif jbt.state == JBT_STATE.loading then
    if train.state ~= defines.train_state.wait_station then
      jbt.state = JBT_STATE.hauling
    end
  elseif jbt.state == JBT_STATE.hauling then
    if train.state == defines.train_state.wait_station and train.station ~= nil then
      if train.station == jbt.job.stop then
        jbt.state = JBT_STATE.arrived
      end
    end
  end
end

script.on_init(
  function()
    global.station_resources = {}
    global.jobs = {}
  end
)

script.on_nth_tick(2, delivery_tick)
script.on_nth_tick(60, interval_1s)
script.on_nth_tick(600, interval_10s)
-- script.on_nth_tick(3600, interval_60s)
script.on_event(defines.events.on_train_changed_state, train_changed_state)
