-- Defaults
-- TODO: Make these settings

ITEM_TIMEOUT = 15 * 60
TRAIN_TIMEOUT = 20 * 60
DATA_VERSION = 29
WORST_CASE = 2 -- Assume a delivery *might* take twice as long as it should
SUBSUME_NEW_TRAINS = false
DELIVERY_TICKS = 2
MIN_DISTANCE_BETWEEN_PICKUPS = 20
NEVER_UNDERFILL = true

INSERTER_DIRECTION = {
  ['pickup_position'] = 'drop_target',
  ['drop_position'] = 'pickup_target'
}

INSERTER_FORCE_STACK_BONUS = {
  ['stack-filter-inserter'] = 'stack_inserter_capacity_bonus',
  ['filter-inserter'] = 'inserter_stack_size_bonus'
}

-- Load dependencies
get_distance = require('__flib__.misc').get_distance

function reset_global(full_reset)
  local full_reset = full_reset or false

  if full_reset or global.data_version == nil or global.data_version < DATA_VERSION then
    global = {
      data_version=DATA_VERSION,
      station_meta={},
      stations={},
      requests={},
      provides={},
      trains={},
      deliveries_in_progress={},
      train_item_cap = 0,
      train_fluid_cap = 0
    }
  end
end

function spairs(t, order)
    -- collect the keys
    local keys = {}
    for k in pairs(t) do keys[#keys+1] = k end

    -- if order function given, sort by it by passing the table and keys a, b,
    -- otherwise just sort the keys 
    if order then
        table.sort(keys, function(a,b) return order(t, a, b) end)
    else
        table.sort(keys)
    end

    -- return the iterator function
    local i = 0
    return function()
        i = i + 1
        if keys[i] then
            return keys[i], t[keys[i]]
        end
    end
end

function sortby(t, sortby)
  return spairs(t, function(t,a,b) return sortby(t[a]) > sortby(t[b]) end)
end

function get_stop_signals(stop)
  local id = stop.unit_number

  if global.station_meta[id] == nil then
    global.station_meta[id] = {
      channel=0,
      tick=0,
      stop=stop,
      signals={ history={} },
      provider=false,
      requester=false,
      automated=false,
      allocated=0,
      debug=false
    }
  end

  local m = global.station_meta[id]

  if m.tick == game.tick then
    return m
  end

  -- Do the update
  local config = stop.get_or_create_control_behavior()
  local train = stop.get_stopped_train()
  local signals = {
    train={},
    data={},
    history={}
  }
  local wire

  if train then
    for s,c in pairs(train.get_contents()) do
      signals.train[s] = {signal={name=s,type="item"}, count=c}
    end
    for s,c in pairs(train.get_fluid_contents()) do
      signals.train[s] = {signal={name=s,type="fluid"}, count=c}
    end
  end

  m.provider = false
  m.requester = false
  m.automated = false
  m.debug = false
  local needs = {}

  for _,c in pairs(stop.circuit_connection_definitions) do
    wire = c.wire
    for _,s in pairs(stop.get_circuit_network(c.wire).signals or {}) do
      local count = s.count

      if s.signal.name == "ssl-role-provide" then
        m.provider = true
      elseif s.signal.name == "ssl-role-request" then
        m.requester = true
      elseif s.signal.name == "ssl-role-automate" then
        m.automated = true
      elseif s.signal.name == "signal-D" then
        m.debug = true
      elseif s.signal.type ~= 'virtual' then
        if count < 0 then
          needs[s.signal.name] = {
            signal=s.signal,
            amount=(0 - count)
          }
          if signals.data[s.signal.name] == nil or signals.data[s.signal.name].tick < game.tick then
            signals.data[s.signal.name] = {signal=s.signal,count=count, tick=game.tick}
          end
          signals.history[s.signal.name] = needs[s.signal.name]
        elseif count > 0 then
          if config.read_from_train and signals.train[s.signal.name] then
            -- To get an accurate figure, we subtract the train contents
            count = count - signals.train[s.signal.name].count
          end
          signals.data[s.signal.name] = {signal=s.signal,count=count, tick=game.tick}
        end
        signals.history[s.signal.name] = signals.data[s.signal.name]
      end
    end
  end

  if m.signals.history == nil then
    -- No history
  else
    for n,s in pairs(m.signals.history) do
      if signals.data[n] == nil then
        if s.tick + ITEM_TIMEOUT >= game.tick then
          -- This signal is timing out, but not gone yet
          signals.history[n] = s
        else
          signals.history[n] = nil
        end
      end
    end
  end 

  if m.requester then
    for name,data in pairs(needs) do
      amount = data.amount
      request_key = id..":"..name

      if global.requests[request_key] == nil then
        global.requests[request_key] = {
          channel=0,
          stop=stop,
          meta=m,
          item=name,
          amount=amount,
          current=0,
          pending=0,
          satisfied=false,
          priority=0,
          wait_tick=game.tick,
          signal=data.signal,
          last_delivery=game.tick,
          consumption_rate=amount/60,
          delivery_trend_calc = game.tick,
          delivery_time=60,
          deliveries={},
          seen = game.tick,
        }
      end
      request = global.requests[request_key]
      request.seen = game.tick
      request.amount = amount

      local needed = math.floor((request.amount - request.current) + (request.consumption_rate * request.delivery_time * WORST_CASE)) - request.pending

      request.satisfied = false
      if signals.data[name] ~= nil and signals.data[name].count >= needed then
        -- game.print("We have "..serpent.line(signals.data[name]).." and need "..amount)
        request.satisfied = true
      end

      if signals.data[name] ~= nil and signals.data[name].count > 0 then
        request.current = signals.data[name].count
      else
        request.current = 0
      end

      local wait_priority = 0
      if request.train ~= nil and needed > 0 then
        -- waiting for a train
        wait_priority = (game.tick - request.wait_tick) / 600
      else
        request.wait_tick = game.tick
      end

      if game.tick - (request.delivery_trend_calc or 0)> 300 then
        -- At least once per minute do a recalc
        local tmp = {
          dest = request,
          tick = request.last_delivery,
          delivery = 0,
          current_at_schedule_time = request.current,
        }
        update_delivery_trends(tmp, false)

      end

      request.priority = math.floor(math.log10(needed) * 10) + wait_priority
      if m.debug then
        game.print("Debug "..stop_to_s(m.stop).."REQ:\n"..serpent.line(request))
      end
    end
  end

  m.signals = signals
  m.tick = game.tick

  if m.debug then
    game.print("Debug "..stop_to_s(m.stop)..": "..serpent.line(m))
  end

  return m
end

function set_stop_name(stop, meta)
  tag = string.match(stop.backer_name, '#%s*(.*)')

  local prefix
  if meta.provider and meta.requester then
    prefix = 'BUFFER: '
  elseif meta.provider then
    prefix = 'SOURCE: '
  elseif meta.requester then
    prefix = 'SINK: '
  else
    return
  end

  local items = {}
  for _,s in pairs(meta.signals.history) do
    if s.signal.type ~= 'virtual' then
      if s.count >= 0 or meta.requester then
        items[#items+1] = "[img="..s.signal.type.."."..s.signal.name.."]"
      end
    end
  end

  table.sort(items)
  name = prefix .. table.concat(items)
  if tag ~= nil then
    name = name .. '#' .. tag
  end
  if stop.backer_name ~= name then
    game.print("Rename Stop "..stop.backer_name.." to "..name.." because it has history "..serpent.line(meta.signals.history))
    stop.backer_name = name
  end
end

function for_each_station(func)
  local stopid

  for _, force in pairs(game.forces) do
    for _, stop in pairs(force.get_train_stops()) do
      local meta = get_stop_signals(stop)
      func(stop, meta)
    end
  end
end

function for_each_request(func)
  for key, request in spairs(global.requests, function(t,a,b) return t[a].priority > t[b].priority end) do
    func(key, request)
  end
end

function handle_request(key, request, trains)
  -- game.print("REQUEST: "..serpent.line(request))
  if request.satisfied then
    -- game.print("Satisfied")
    return
  end

  if not request.meta.requester or request.seen ~= game.tick then
    game.print("Delete request "..key.." = "..serpent.line(request))
    global.requests[key] = nil
    return
  end

  local current = request.amount - request.current
  local over_time = math.floor(request.consumption_rate * request.delivery_time * WORST_CASE)

  local needed = current + over_time - request.pending
  -- game.print(key.." at stop "..stop_to_s(request.stop)..": Needed "..needed.." based on current "..current..", over time "..over_time.." and pending "..request.pending)

  if needed <= request.amount then
    if request.meta.debug then
      game.print("No delivery. "..needed.." <= "..request.amount)
    end
    return
  end

  local proto = game.item_prototypes[request.item]
  local needed_capacity
  local needed_wagons
  if request.signal.type == 'fluid' then
    needed_capacity = math.ceil(needed / 25000)
    if needed_capacity > global.train_fluid_cap then
      needed_capacity = global.train_fluid_cap
      needed = 25000 * needed_capacity
    end
    needed_wagons = needed_capacity
  elseif request.signal.type == 'item' then
    needed_capacity = math.ceil(needed /proto.stack_size)
    needed_wagons = math.ceil(needed_capacity / 40)
    capacity_key = 'capacity'
    if needed_wagons > global.train_item_cap then
      needed_capacity = global.train_item_cap
      needed_wagons = needed_capacity / 40
      needed = needed_capacity * proto.stack_size
    end
  end

  local train
  -- game.print("Searching for "..request.item)

  local candidates = {}
  local total_amount = 0

  for id, meta in pairs(global.station_meta) do
    if meta.provider then
      stock = meta.signals.data[request.item]
      if stock ~= nil then
        pending_stock = stock.count - meta.allocated
        if pending_stock > 0 then
          table.insert(candidates, { id=id, meta=meta, amount=pending_stock })
          total_amount = total_amount + pending_stock
        end
      end
    end
  end

  local best_remaining = { index = nil, wagons = 0 }
  local skip
  -- game.print("NEEDED: "..needed_wagons..": "..needed)
  local sorted_trains = sortby(trains,
    function(t)
      if t == nil then
        return 0
      end
      local held
      local real_capacity
      local wagon_key
      if request.signal.type == 'fluid' then
        held = (t.fluids[request.item] or 0) / 25000
        real_capacity = t.fluid_capacity + held
        if real_capacity == 0 then return 0 end
        wagon_key = 'fluid_wagons'
      else
        held = (t.items[request.item] or 0)
        real_capacity = t.capacity / proto.stack_size + held
        if real_capacity == 0 then return 0 end
        wagon_key = 'wagons'
      end
      if real_capacity >= needed_capacity then
        if t.wagons == needed_wagons then
          return 100000 + real_capacity + held
        else
          return 50000 + real_capacity + held
        end
      end

      if t[wagon_key] > needed_wagons then
        return 40000 + real_capacity + held
      else
        return real_capacity + held
      end

    end
  )
  for i,t in sorted_trains do
    -- game.print(serpent.line(t))
    
    skip = false
    if #candidates == 0 then
      if t.items[request.item] == 0 then
        -- we have no source for the goods. We only want trains with some of the item
        skip = true
      end
    end

    local real_capacity = 0
    if request.signal.type == 'fluid' then
      held = (t.fluids[request.item] or 0) / 25000
      real_capacity = t.fluid_capacity + held
      wagon_key = 'fluid_wagons'
    else
      held = (t.items[request.item] or 0)
      real_capacity = t.capacity / proto.stack_size + held
      wagon_key = 'wagons'
    end

    if real_capacity == 0 then
      -- The train is full and does not have the item we need
      skip = true
    end

    if not skip then
      if t[wagon_key] >= needed_wagons then
        -- game.print(serpent.line(t))
        train = t
        table.remove(trains,i)
        break
      else
        if best_remaining.wagons < t[wagon_key] then
          best_remaining.index = i
          best_remaining.wagons = t[wagon_key]
        end
      end
    end
  end

  if total_amount < needed and NEVER_UNDERFILL then
    if request.meta.debug then
      game.print("No delivery. NEVER_UNDERFILL and "..total_amount.." <= "..needed.."("..needed_capacity..")")
    end

    if train ~= nil then
      -- Stuff the train back onto the list
      trains[#trains+1] = train
    end
    return
  end

  if train == nil then
    if best_remaining.wagons > 0 then
      if wagon_key == 'fluid_wagons' then
        needed = trains[best_remaining.index].wagons * 25000
      else
        needed = trains[best_remaining.index].wagons * 40 * proto.stack_size
      end 
      -- game.print("Using a train with space for "..needed.." of "..request.item.." --- "..serpent.line(trains[best_remaining.index]))
      train = table.remove(trains,best_remaining.index)
    else
      -- No trains left
      if request.meta.debug then
        game.print("No trains with at least "..needed_wagons.." wagons")
        game.print(serpent.line(trains))
      end
      return
    end
  end

  local on_board

  if request.signal.type == 'fluid' then
    on_board = train.train.get_fluid_count(request.item)
  elseif request.signal.type == 'item' then
    on_board = train.train.get_item_count(request.item)
  end

  if (total_amount + on_board) < needed and NEVER_UNDERFILL == true then
    return
  end

  schedule_train(train.train, candidates, request, needed, on_board)
end

function schedule_train(train, candidates, request, amount, on_board)
  -- game.print("Assing train: "..serpent.line(train))
  -- game.print("Scheduling a train for "..amount.." "..request.item.." to stop "..stop_to_s(request.stop).." which is pending "..request.pending)
  local schedule = {}
  local allocated = 0
  local st_amount = 0
  local stops = {}
  allocated = on_board

  local pickup_stops = 0
  local last_location
  local distance
  if (amount - allocated) > 0 then
    for _,c in spairs(candidates, function(t,a,b) return t[a].amount > t[b].amount end) do

      if last_location == nil then
        last_location = c.meta.stop.position
        distance = 1000000000
      else
        distance = get_distance(last_location, c.meta.stop.position)
        last_location = c.meta.stop.position
      end

      if distance >= MIN_DISTANCE_BETWEEN_PICKUPS then
        st_amount = amount - allocated
        if st_amount > c.amount then
          st_amount = c.amount
        end

        schedule[#schedule+1] = path_to(c.meta.stop)
        allocated = allocated + st_amount
        schedule[#schedule+1] = generate_pickup(c.meta.stop, request, allocated)
        c.meta.stop.trains_limit = 1
        stops[#stops+1] = {
          meta = c.meta,
          stop = c.meta.stop,
          task = 'load',
          items = {
            { item=request.item, count=st_amount, pending=0, plans={} }
          },
          request = request,
          allocated = allocated,
          count = st_amount
        }
        c.meta.allocated = c.meta.allocated + st_amount

        pickup_stops = pickup_stops + 1
        if allocated == amount then
          break
        end
      end
    end
  end

  if pickup_stops == 0 then
    if on_board > 0 then
      game.print("Delivery from on-board stock - "..on_board)
    else
      -- game.print("Could not find a source for "..request.item)
      return
    end
  end

  schedule[#schedule+1] = path_to(request.stop)
  schedule[#schedule+1] = generate_delivery(request, allocated)
  schedule[#schedule+1] = { station="DEPOT" }

  request.stop.trains_limit = 1
  stops[#stops+1] = {
    request = request,
    stop = request.stop,
    task = 'unload',
    items = {
      { item=request.item, count=allocated, pending=0, plans={} }
    },
    ref = request.signal,
    count = allocated
  }

  -- game.print("Schedule "..serpent.line(schedule))
  game.print("Schedule "..allocated.." "..request.item.." for "..stop_to_s(request.stop))

  train.schedule = {
    current=1,
    records=schedule
  }
  request.train = train
  request.train_tick = game.tick
  request.pending = request.pending + allocated
  global.trains[train.id] = {
    train = train,
    dest = request,
    delivery = allocated,
    tick = game.tick,
    current_at_schedule_time = request.current,
    at_station = false,
    stops = stops
  }
end

function clear_task(data, task)
  -- game.print("Clearing task: "..serpent.line(task).." at "..stop_to_s(task.stop))
  if task.task == 'load' then
    -- remove the pending item from the source
    task.meta.allocated = task.meta.allocated - task.count
  elseif task.task == 'unload' then
    data.dest.train_tick = 0
    data.dest.train = nil
    data.dest.pending = data.dest.pending - data.delivery
    update_delivery_trends(data, true)
  end
end

function train_changed_state(event)
  local train = event.train
  local data = global.trains[train.id]
  if data == nil then
    return
  end
  local expected = data.stops[1]
  if expected == nil then
    return
  end

  if data.at_station == true then
    -- clear the last stop
    data.at_station = false
    if expected.task == 'unload' and data.dest.current == 0 then
      -- game.print("Stop "..stop_to_s(data.dest.stop).." ran out of stock. Doubling consumption rate to try to deliver more")
      -- data.dest.consumption_rate = data.dest.consumption_rate * 2
    end
    clear_task(data, expected)
    table.remove(data.stops,1)
    end_delivery_in_progress(train)
  elseif train.state == defines.train_state.wait_station and train.station ~= nil then

    -- game.print("TRP "..stop_to_s(expected.stop).." - "..serpent.line(expected))

    if train.station ~= expected.stop then
      local current = train.schedule.records[train.schedule.current]
      local abort = false
      if current.wait_conditions ~= nil then
        for _,condition in pairs(current.wait_conditions) do
          if condition.type == 'item_count' then
            abort = true
          end
        end
      end

      if abort then
        game.print("Train "..train.id.." has abandoned its request. Cleanup.")
        game.print("Was expected at "..expected.stop.unit_number.." but is at "..train.station.unit_number)

        clear_train_actions(train.id)
      end
    elseif expected.task == 'load' then
      -- game.print("Train "..train.id.." ARRIVED "..expected.stop.backer_name.." FOR PICKUP")
      data.at_station = true

      delivery_in_progress(train, expected)
    elseif expected.task == 'unload' then
      -- game.print("Train "..train.id.." ARRIVED "..expected.stop.backer_name.." FOR DROPOFF")
      data.at_station = true
      delivery_in_progress(train, expected)
    end
  end
end

function update_delivery_trends(data, update)

  local now = game.tick
  local request = data.dest
  local elapsed_time = (now - request.last_delivery) / 60
  local delivery_time = (now - data.tick) / 60
  local consumed = data.delivery + (data.current_at_schedule_time - request.current)
  if consumed < 0 then consumed = 0 end
  local consumption_rate = consumed / elapsed_time -- consumption in items/sec

  -- game.print("CON: "..consumed.." CR: "..consumption_rate.." DT: "..delivery_time)

  if consumed > 0 then
    local consumption_diff = (consumption_rate - request.consumption_rate) / 10
    request.consumption_rate = request.consumption_rate + consumption_diff
    if request.consumption_rate < 0 then request.consumption_rate = 0.1 end
  elseif request.consumption_rate < 0 then
    request.consumption_rate = 0.1
  end

  if update == true then
    request.last_delivery = now
    local delivery_time_diff = (elapsed_time - request.delivery_time) / 10
    request.delivery_time = request.delivery_time + delivery_time_diff
  end
  -- game.print("CD: "..consumption_diff.." DD: "..delivery_time_diff)

  -- game.print("Re-calculated trends for "..stop_to_s(request.stop)..": rate: "..request.consumption_rate.." delivery time: "..request.delivery_time)
  request.delivery_trend_calc = now
end

function stop_to_s(stop)
  return stop.unit_number .. ':' .. stop.backer_name
end

function path_to(stop)
  return {
    rail = stop.connected_rail,
    wait_conditions={
      {
        type="time",
        compare_type="and",
        ticks=0
      }
    },
    temporary=true
  }
end

function generate_pickup(stop, request, amount)
  local type
  if request.signal.type == 'item' then
    type = "item_count"
  elseif request.signal.type == 'fluid' then
    type = "fluid_count"
  end

  return {
    station=stop.backer_name,
    temporary=true,
    wait_conditions={
      {
        type=type,
        compare_type = "or",
        condition={
          comparator = ">=",
          first_signal=request.signal,
          constant=amount
        }
      },
      {
        type="inactivity",
        compare_type = "or",
        ticks=60 * 5
      }
    }
  }
end

function generate_delivery(request, amount)
  local type
  if request.signal.type == 'item' then
    type = "item_count"
  elseif request.signal.type == 'fluid' then
    type = "fluid_count"
  end

  return {
    station=request.stop.backer_name,
    temporary=true,
    wait_conditions={
      {
        type=type,
        compare_type="and",
        condition={
          comparator="=",
          first_signal=request.signal,
          constant=0
        }
      },
      {
        type="inactivity",
        compare_type = "or",
        ticks=60 * 5
      }
    }
  }
end

function interval_1s(event)
-- Init. This will wipe all data if there is a version bump
  reset_global()
  trains = {}

  for_each_station(
    function(stop, meta)
      set_stop_name(stop, meta)
      
      train = stop.get_stopped_train()
      if train ~= nil then
        if stop.backer_name == 'DEPOT' then
          stop.trains_limit = 1
          -- Get the size of the train!
          local wagons = 0
          for _,c in pairs(train.cargo_wagons) do
            wagons = wagons + 1
          end
          if (wagons *40) > (global.train_item_cap or 0) then
            global.train_item_cap = wagons*40
          end

          local fluid_wagons = 0
          local used_fluid_capacity = 0
          for _f in pairs(train.fluid_wagons) do
            fluid_wagons = fluid_wagons + 1
          end
          if fluid_wagons > (global.train_fluid_cap or 0) then
            global.train_fluid_cap = fluid_wagons
          end
          local fluids = train.get_fluid_contents()
          for n,f in pairs(fluids) do
            -- Each fluid wagon is effectively a single unit
            used_fluid_capacity = used_fluid_capacity + math.ceil(f / 25000)
          end
          local free_fluid_capacity = fluid_wagons - used_fluid_capacity
          
          local used_capacity = 0
          local proto
          local items = train.get_contents()
          for n,c in pairs(items) do
            proto = game.item_prototypes[n]
            used_capacity = math.ceil(c / proto.stack_size)
          end
          local free_capacity = (wagons * 40) - used_capacity

          trains[#trains+1] = {
            train=train,
            wagons=wagons,
            fluid_wagons = fluid_wagons,
            capacity=free_capacity,
            items=items,
            fluid_capacity=free_fluid_capacity,
            fluids=fluids
          }
        end
      end
    end
  )

  if trains[1] == nil then
    --game.print("There are no available trains "..serpent.line(trains))
    return
  end

  for_each_request(
    function(key, request)
      handle_request(key, request, trains)
    end
  )
end

function train_removed(event)
  if not event.entity or not event.entity.train or not event.entity.valid then return end
  local train = event.entity.train

  if train_has_actions(train.id) then clear_train_actions(train.id) end
end

function train_has_actions(id)
  if global.trains[id] ~= nil then return true end
  return false
end

function transfer_train_actions(id, train)
  local config = global.trains[id]
  if config == nil then return end

  local schedule = {
    current = 1,
    records = {}
  }
  local records = schedule.records
  for _,task in pairs(config.stops) do
    if task.task == 'load' then
      records[#records+1] = path_to(task.stop)
      records[#records+1] = generate_pickup(task.stop, task.request, task.allocated)
    elseif task.task == 'load' then
      records[#records+1] = path_to(task.stop)
      records[#records+1] = generate_delivery(task.request, task.count)
    end
  end
  global.trains[id] = nil
  global.trains[train.id] = config
  train.schedule = schedule
  train.manual_mode = false
end

function clear_train_actions(id)
  if global.trains[id] == nil then return end
  local data = global.trains[id]
  for _,task in pairs(data.stops) do
    clear_task(data, task)
  end
  global.trains[id] = nil
end

function train_created(event)
  game.print("Train created: "..serpent.line(event))
  local updated = false
  local train = event.train

  if event.old_train_id_1 then
    if train_has_actions(event.old_train_id_1) then
      transfer_train_actions(event.old_train_id_1, train)
      updated = true
    end
  end

  if event.old_train_id_2 then
    if train_has_actions(event.old_train_id_2) then
      transfer_train_actions(event.old_train_id_2, train)
      updated = true
    end
  end

  if not updated then
    -- This is an entirely new train
    if SUBSUME_NEW_TRAINS then
      send_train_to_depot(train)
    end
  end
end

function send_train_to_depot(train)
  if train == nil then return end
  train.schedule = {
    current = 1,
    records = { station="DEPOT" }
  }
  train.manual_mode = false
end

function train_schedule_changed(event)
  -- game.print("SCCH: "..serpent.line(event))
end

function delivery_in_progress(train, task)
  local inserters = get_filter_inserters(train, task)
  local key="t"..train.id

  -- game.print("Start DIP "..key)
  global.deliveries_in_progress[key] = {
    task = task,
    train = train,
    inserters = inserters.list,
    count = inserters.count
  }

  -- game.print(serpent.line(global.deliveries_in_progress))
end

function get_rolling_stock(train)
  local stock = {}
  for _,c in pairs(train.cargo_wagons) do
    table.insert(stock, c)
  end

  return stock
end

function get_filter_inserters(train, task)
  local count = 0
  local inserters = {}
  local inserter
  local surface = train.station.surface

  local target
  if task.task == 'load' then
    target = 'drop_position'
  else
    target = 'pickup_position'
  end

  for _,w in pairs(get_rolling_stock(train)) do
    for _,e in pairs(surface.find_entities_filtered({position=w.position,radius=10, type='inserter'})) do
      if string.find(e.name, 'filter') then
        for _, c in pairs(surface.find_entities_filtered{position=e[target]}) do
          if c == w then
            -- This is a filter inserter that targets our wagon
            if e.inserter_filter_mode == 'whitelist' and e.get_filter(1) == nil then
              -- We only control filters in whitelist mode with no filters set
              e.inserter_stack_size_override = 1
              local ikey = "i"..e.unit_number
              inserter = {
                size_key = (INSERTER_FORCE_STACK_BONUS[e.name] or 'inserter_stack_size_bonus'),
                inserter = e,
                step = 0
              }
              inserters[ikey] = inserter
              count = count + 1
            end
          end
        end
      end
    end
  end

  return {
    list = inserters, 
    count = count
  }
end

function end_delivery_in_progress(train)
  local key="t"..train.id
  --game.print("End DIP "..key)
  for id,i in pairs(global.deliveries_in_progress[key].inserters) do
    reset_inserter(i)
  end
  global.deliveries_in_progress[key].inserters = nil
  --game.print("DONE: "..serpent.line(global.deliveries_in_progress[key]))
  global.deliveries_in_progress[key] = nil
end

function delivery_tick(event)
  local id
  local delivery
  for id, delivery in pairs(global.deliveries_in_progress or {}) do
    local task = delivery.task
    local train = delivery.train
    if not task.stop.valid or not train.valid then return end
    local meta = get_stop_signals(task.stop)

    -- log(serpent.line(delivery))
    local current = delivery.task.items[1]

    for id, i in pairs(delivery.inserters) do
      current = update_inserter(delivery, id, i, meta, current)
    end
  end
end

function reset_inserter(i)
  i.inserter.inserter_stack_size_override = 1
  i.inserter.set_filter(1, nil)
  i.stack = nil
end

function update_inserter(delivery, id, i, meta, current)
  local count = delivery.inserter_count
  if not i.inserter.valid then
    delivery.inserters[id] = nil
    -- log(id..": No longer valid. Delete")
    return current
  end

  local max_stack = 1 + i.inserter.force[i.size_key]

  if current == nil then
    -- We're done here
    reset_inserter(i)
    return nil
  end

  local source = i.inserter.pickup_target

  if i.plans == nil then i.plans = {} end
  if i.plans[id] == nil then i.plans[id] = { item=current.irem, count=0 } end

  if i.step == 0 then
    -- Plan
    local wanted = current.count - current.pending
    if wanted >= max_stack then
      -- Plan to pick up the max stack size of item
      i.inserter.set_filter(1, current.item)
      i.inserter.inserter_stack_size_override = max_stack
      current.pending = current.pending + max_stack
      i.plans[id] = { item=current.item, count=max_stack }
      -- log(id.."("..i.step.."): Plan: load "..max_stack.." of "..current.item)
      i.step = 1
    elseif wanted > 0 then
      -- Plan to pick up the last amount of item
      i.inserter.set_filter(1, current.item)
      i.inserter.inserter_stack_size_override = wanted
      current.pending = current.pending + wanted
      i.plans[id] = { item=current.item, count=wanted }
      -- log(id.."("..i.step.."): Plan: load "..wanted.." of "..current.item)
      i.step = 1
    else
      -- we have allocated everything. Plan to do nothing this tick
      reset_inserter(i)
      -- log(id.."("..i.step.."): Reset")
    end
  elseif i.step == 1 then
    -- We are waiting until something is held
    local held = i.inserter.held_stack
    local plan = i.plans[id]
    if held and held.valid_for_read then
      plan.held = { item=held.name, count=held.count }
      -- log(id.."("..i.step.."): Picked up "..held.count.." of "..held.name)
      i.step = 2
    end
  elseif i.step == 2 then
    -- We are waiting to release the item held
    local held = i.inserter.held_stack
    if held == nil or not held.valid_for_read then
      -- log(id.."("..i.step.."): Dropped off "..i.plans[id].held.count.." of "..i.plans[id].held.item)
      i.step = 3
    end
  elseif i.step == 3 then
    -- The item has been delivered. Bookkeeping.
    local plan = i.plans[id]
    current.pending = current.pending - plan.count 
    if plan.held.item == plan.item then
      -- log(id.."("..i.step.."): Finalise bookkeeping")
      -- it was the correct item
      current.count = current.count - plan.held.count

      if current.count <= 0 then
        table.remove(delivery.task.items, 1)
        current = delivery.task.items[1]
      end
    else
      -- log(id.."("..i.step.."): WRONG ITEM")
    end
    i.step = 0
    i.plans[id] = nil
  else
    -- log(id.." INVALID STEP: "..i.step)
  end

  return current
end

script.on_init(
  function(event)
    reset_global(false)
  end
)
script.on_nth_tick(DELIVERY_TICKS, delivery_tick)
script.on_nth_tick(60, interval_1s)

script.on_event(defines.events.on_train_changed_state, train_changed_state)
script.on_event(defines.events.on_train_created, train_created)
script.on_event(defines.events.on_train_schedule_changed, train_schedule_changed)

fTrain = {{filter='rolling-stock'}}
script.on_event(defines.events.on_pre_player_mined_item, train_removed, fTrain)
script.on_event(defines.events.on_robot_pre_mined, train_removed, fTrain)
script.on_event(defines.events.on_entity_died, train_removed, fTrain)
script.on_event(defines.events.script_raised_destroy, train_removed, fTrain)
