/var/global/running_demand_events = list()

/hook/sell_shuttle/proc/supply_demand_sell_shuttle(var/area/area_shuttle)
	for(var/datum/event/supply_demand/E in running_demand_events)
		E.handle_sold_shuttle(area_shuttle)
	return 1 // All hooks must return one to show success.

//
// The Supply Demand Event - CentCom asks for us to put some stuff on the shuttle
//
/datum/event/supply_demand
	var/my_department = "Supply Division"
	var/list/required_items = list()
	var/end_time
	announceWhen = 1
	startWhen = 2
	endWhen = 1800 // Aproximately 1 hour in master controller ticks, refined by end_time

/datum/event/supply_demand/setup()
	my_department = "[using_map.company_name] Supply Division" // Can't have company name in initial value (not const)
	end_time = world.time + 1 HOUR + (severity * 30 MINUTES)
	running_demand_events += src
	// Decide what items are requried!
	// We base this on what departmets are most active, excluding departments we don't have
	var/list/notHaveDeptList = metric.departments.Copy()
	notHaveDeptList.Remove(list(ROLE_ENGINEERING, ROLE_MEDICAL, ROLE_RESEARCH, ROLE_CARGO, ROLE_CIVILIAN))
	var/deptActivity = metric.assess_all_departments(severity * 2, notHaveDeptList)
	for(var/dept in deptActivity)
		switch(dept)
			if(ROLE_ENGINEERING)
				choose_atmos_items(severity + 1)
			if(ROLE_MEDICAL)
				choose_chemistry_items(roll(severity, 3))
			if(ROLE_RESEARCH) // Would be nice to differentiate between research diciplines
				choose_research_items(roll(1, 3))
				choose_robotics_items(roll(1, 3))
			if(ROLE_CARGO)
				choose_alloy_items(rand(1, severity))
			if(ROLE_CIVILIAN) // Would be nice to separate out chef/gardener/bartender
				choose_food_items(roll(severity, 2))
				choose_bar_items(roll(severity, 3))
	if(required_items.len == 0)
		choose_bar_items(rand(5, 10)) // Really? Well add drinks. If a crew can't even get the bar open they suck.

/datum/event/supply_demand/announce()
	var/message = "[using_map.company_short] is comparing accounts and the bean counters found our division is "
	message += "a few items short.  We have to fill that gap quick before anyone starts asking questions. "
	message += "You'd better have this here stuff by [worldtime2stationtime(end_time)]<br>"
	message += "The requested items are as follows"
	message += "<hr>"
	for (var/datum/supply_demand_order/req in required_items)
		message += req.describe() + "<br>"
	message += "<hr>"
	message += "Deliver these items to [command_name()] via the supply shuttle.  Make sure to package them into crates!<br>"

	for(var/dpt in req_console_supplies)
		send_console_message(message, dpt);

	// Also announce over main comms so people know to look
	command_announcement.Announce("An order for the station to deliver supplies to [command_name()] has been delivered to all supply Request Consoles", my_department)

/datum/event/supply_demand/tick()
	if(required_items.len == 0)
		endWhen = activeFor  // End early becuase we're done already!

/datum/event/supply_demand/end()
	running_demand_events -= src
	// Check if the crew succeeded or failed!
	if(required_items.len == 0)
		// Success!
		supply_controller.points += 200
		command_announcement.Announce("Congrats! You delivered everything!", my_department)
	else
		// Fail!
		supply_controller.points = supply_controller.points / 2
		command_announcement.Announce("Booo! You failed to deliver some stuff!", my_department)

/**
 * Event Handler for responding to the supply shuttle arriving at centcom.
 */
/datum/event/supply_demand/proc/handle_sold_shuttle(var/area/area_shuttle)
	var/match_found = 0;

	for(var/atom/movable/MA in area_shuttle)
		// Special case to allow us to count mechs!
		if(MA.anchored && !istype(MA, /obj/mecha))	continue // Ignore anchored stuff

		// If its a crate, search inside of it for matching items.
		if(istype(MA, /obj/structure/closet/crate))
			for(var/atom/item_in_crate in MA)
				match_found |= match_item(item_in_crate)
		else
			// Otherwise check it against our list
			match_found |= match_item(MA)

	if(match_found && required_items.len > 1)
		// Okay we delivered SOME.  Lets give an update, but only if not finished.
		var/message = "Shipment Received.  As a reminder, the following items are still requried:"
		message += "<hr>"
		for (var/datum/supply_demand_order/req in required_items)
			message += req.describe() + "<br>"
		message += "<hr>"
		message += "Deliver these items to [command_name()] via the supply shuttle.  Make sure to package them into crates!<br>"
		send_console_message(message, "Cargo Bay")

/**
 * Helper method to check an item against the list of required_items.
 */
/datum/event/supply_demand/proc/match_item(var/atom/I)
	for(var/datum/supply_demand_order/meta in required_items)
		if(meta.match_item(I))
			if(meta.qty_need <= 0)
				required_items -= meta
			return 1
	return 0 // Nothing found if we get here

/**
 * Utility method to send message to request consoles.
 * @param message - Message to send
 * @param to_department - Name of department to deliver to, or null to send to all departments.
 * @return 1 if successful, 0 if couldn't send.
 */
/datum/event/supply_demand/proc/send_console_message(var/message, var/to_department)
	for(var/obj/machinery/message_server/MS in world)
		if(!MS.active) continue
		MS.send_rc_message(to_department ? to_department : "All Departments", my_department, message, "", "", 2)

//
//  Supply Demand Datum - Keeps track of what centcomm has demanded
//

/datum/supply_demand_order
	var/name		// Name of the item
	var/qty_orig // How much was requested
	var/qty_need // How much we still need

/datum/supply_demand_order/New(var/qty)
	if(qty) qty_orig = qty
	qty_need = qty_orig

/datum/supply_demand_order/proc/describe()
	return "[name] - (Qty: [qty_need])"

/datum/supply_demand_order/proc/match_item(var/atom/I)
	return 0

//
// Request is for a physical thing
//
/datum/supply_demand_order/thing
	var/atom/type_path // Type path of the item required

/datum/supply_demand_order/thing/New(var/qty, var/atom/type_path)
	..()
	src.type_path = type_path
	src.name = initial(type_path.name)
	if(!name)
		log_debug("supply_demand event: Order for thing [type_path] has no name.")

/datum/supply_demand_order/thing/match_item(var/atom/I)
	if(istype(I, type_path))
		// Hey, we found it!  How we handle it depends on some details tho.
		if(istype(I, /obj/item/stack))
			var/obj/item/stack/S = I
			var amount_to_take = min(S.get_amount(), qty_need)
			S.use(amount_to_take)
			qty_need -= amount_to_take
		else
			qty_need -= 1
			qdel(I)
		return 1

//
// Request is for an amount of some reagent
//
/datum/supply_demand_order/reagent
	var/reagent_id

/datum/supply_demand_order/reagent/New(var/qty, var/datum/reagent/R)
	..()
	name = R.name
	reagent_id = R.id

/datum/supply_demand_order/reagent/describe()
	return "[qty_need] units of [name] in glass containers"

// In order to count it must be in a beaker or pill! Whole number units only
/datum/supply_demand_order/reagent/match_item(var/atom/I)
	if(!I.reagents)
		return
	if(!istype(I, /obj/item/weapon/reagent_containers/glass) && !istype(I, /obj/item/weapon/reagent_containers/pill))
		return
	var/amount_to_take = min(I.reagents.get_reagent_amount(reagent_id), qty_need)
	if(amount_to_take >= 1)
		I.reagents.remove_reagent(reagent_id, amount_to_take, safety = 1)
		qty_need -= amount_to_take
		return 1
	return

//
// Request is for a gas mixture.
//	In this case the target is moles!
//
/datum/supply_demand_order/gas
	name = "Gas Mixture"
	var/datum/gas_mixture/mixture

/datum/supply_demand_order/gas/describe()
	var/pressure = mixture.return_pressure()
	var/total_moles = mixture.total_moles
	var desc = "Canister filled to [round(pressure,0.1)] kPa with gas mixture:\n"
	for(var/gas in mixture.gas)
		desc += "<br>- [gas_data.name[gas]]: [round((mixture.gas[gas] / total_moles) * 100)]%\n"
	return desc

/datum/supply_demand_order/gas/match_item(var/obj/machinery/portable_atmospherics/canister)
	if(!istype(canister))
		return
	var/datum/gas_mixture/canmix = canister.air_contents
	if(!canmix || canmix.total_moles <= 0)
		return
	if(canmix.return_pressure() < mixture.return_pressure())
		log_debug("supply_demand event: canister fails to match [canmix.return_pressure()] kPa < [mixture.return_pressure()] kPa")
		return
	// Make sure ratios are equal
	for(var/gas in mixture.gas)
		var/targetPercent = round((mixture.gas[gas] / mixture.total_moles) * 100)
		var/canPercent = round((canmix.gas[gas] / canmix.total_moles) * 100)
		if(abs(targetPercent-canPercent) > 1)
			log_debug("supply_demand event: canister fails to match because '[gas]': [canPercent] != [targetPercent]")
			return // Fail!
	// Huh, it actually matches!
	qty_need -= 1
	return 1

//
// Item choosing procs - Decide what supplies will be demanded!
//

/datum/event/supply_demand/proc/choose_food_items(var/differentTypes)
	var/list/types = typesof(/datum/recipe) - /datum/recipe
	for(var/i in 1 to differentTypes)
		var/datum/recipe/R = pick(types)
		types -= R // Don't pick the same thing twice
		var/chosen_path = initial(R.result)
		var/chosen_qty = rand(1, 5)
		required_items += new /datum/supply_demand_order/thing(chosen_qty, chosen_path)
	return

/datum/event/supply_demand/proc/choose_research_items(var/differentTypes)
	var/list/types = typesof(/datum/design) - /datum/design
	for(var/i in 1 to differentTypes)
		var/datum/design/D = pick(types)
		types -= D // Don't pick the same thing twice
		var/chosen_path = initial(D.build_path)
		var/chosen_qty = rand(1, 3)
		required_items += new /datum/supply_demand_order/thing(chosen_qty, chosen_path)
	return

/datum/event/supply_demand/proc/choose_chemistry_items(var/differentTypes)
	// Checking if they show up in health analyzer is good huristic for it being a drug
	var/list/medicineReagents = list()
	for(var/path in typesof(/datum/chemical_reaction) - /datum/chemical_reaction)
		var/datum/chemical_reaction/CR = path // Stupid casting required for reading
		var/datum/reagent/R = chemical_reagents_list[initial(CR.result)]
		if(R && R.scannable)
			medicineReagents += R
	for(var/i in 1 to differentTypes)
		var/datum/reagent/R = pick(medicineReagents)
		medicineReagents -= R // Don't pick the same thing twice
		var/chosen_qty = rand(1, 20) * 5
		required_items += new /datum/supply_demand_order/reagent(chosen_qty, R)
	return

/datum/event/supply_demand/proc/choose_bar_items(var/differentTypes)
	var/list/drinkReagents = list()
	for(var/path in typesof(/datum/chemical_reaction) - /datum/chemical_reaction)
		var/datum/chemical_reaction/CR = path // Stupid casting required for reading
		var/datum/reagent/R = chemical_reagents_list[initial(CR.result)]
		if(istype(R, /datum/reagent/drink) || istype(R, /datum/reagent/ethanol))
			drinkReagents += R
	for(var/i in 1 to differentTypes)
		var/datum/reagent/R = pick(drinkReagents)
		drinkReagents -= R // Don't pick the same thing twice
		var/chosen_qty = rand(1, 20) * 5
		required_items += new /datum/supply_demand_order/reagent(chosen_qty, R)
	return

/datum/event/supply_demand/proc/choose_robotics_items(var/differentTypes)
	var/list/types = list( // Do not make mechs dynamic, its too silly
		/obj/mecha/combat/durand,
		/obj/mecha/combat/gygax,
		/obj/mecha/medical/odysseus,
		/obj/mecha/working/ripley)
	for(var/i in 1 to differentTypes)
		var/T = pick(types)
		types -= T // Don't pick the same thing twice
		required_items += new /datum/supply_demand_order/thing(rand(1, 2), T)
	return

/datum/event/supply_demand/proc/choose_atmos_items(var/differentTypes)
	var/datum/gas_mixture/mixture = new
	mixture.temperature = T20C
	var/unpickedTypes = gas_data.gases.Copy()
	unpickedTypes -= "volatile_fuel" // Don't do that one
	for(var/i in 1 to differentTypes)
		var/gasId = pick(unpickedTypes)
		unpickedTypes -= gasId
		mixture.gas[gasId] = (rand(1,1000) * mixture.volume) / (R_IDEAL_GAS_EQUATION * mixture.temperature)
	mixture.update_values()
	var/datum/supply_demand_order/gas/O = new(qty = 1)
	O.mixture = mixture
	required_items += O
	return

/datum/event/supply_demand/proc/choose_alloy_items(var/differentTypes)
	var/list/types = typesof(/datum/alloy) - /datum/alloy
	for(var/i in 1 to differentTypes)
		var/datum/alloy/A = pick(types)
		types -= A // Don't pick the same thing twice
		var/chosen_path = initial(A.product)
		var/chosen_qty = Floor(rand(5, 100) * initial(A.product_mod))
		required_items += new /datum/supply_demand_order/thing(chosen_qty, chosen_path)
	return

// Silly item existing for debugging this
/obj/item/supply_demand_spawner
	icon = 'icons/obj/module.dmi'
	icon_state = "id_mod"
	var/datum/event/supply_demand/event
/obj/item/supply_demand_spawner/New()
	var/datum/event_meta/EM = new
	EM.name = "Supply & Demand"
	EM.severity = EVENT_LEVEL_MUNDANE
	EM.event_type = /datum/event/supply_demand
	event = new EM.event_type(EM)
