data:extend({
  {
    type = "item-subgroup",
    name = "SSL-signal",
    group = "signals",
    order = "ssl0[SSL-signal]"
  },
--  {
--    type = "virtual-signal",
--    name = "ssl-role-automate",
--    icon = "__SimpleStationLogistics__/icons/ssl-role-automate.png",
--    icon_size = 32,
--    subgroup = "SSL-signal",
--    order = "a-a"
--  },
  {
    type = "virtual-signal",
    name = "ssl-role-provide",
    icon = "__SimpleStationLogistics__/icons/ssl-role-provide.png",
    icon_size = 32,
    subgroup = "SSL-signal",
    order = "a-b"
  },
  {
    type = "virtual-signal",
    name = "ssl-role-request",
    icon = "__SimpleStationLogistics__/icons/ssl-role-request.png",
    icon_size = 32,
    subgroup = "SSL-signal",
    order = "a-c"
  }
})
