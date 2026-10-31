-- Spawn-menu entries (Vehicles > Police) for the RTU SL65 AMG, one per livery

local function add(class, name, skin)
	list.Set("Vehicles", class, {
		Name = name,
		Class = "prop_vehicle_jeep",
		Category = "Police",
		Author = "Tilin",
		Information = "Mercedes SL65 AMG, police RTU. Procedural V12 engine sound with speed/rpm HUD.",
		Model = "models/plpd/sl65amg_rtu.mdl",
		KeyValues = {
			vehiclescript = "scripts/vehicles/plpd/sl65amg_rtu.txt",
			skin = tostring(skin),
		},
	})
end

add("rtu_sl65amg", "SL65 AMG (Police)", 0)
add("rtu_sl65amg_blue", "SL65 AMG (RTU Blue)", 1)
add("rtu_sl65amg_yellow", "SL65 AMG (RTU Yellow)", 2)
