# Simple Station Logistics

This is an early version - late alpha/early beta quality - of a simple logicist mod.
I am releasing it to allow some friends to test easily (If you choose to download and use it, consuder yourself a friend).

This is in no way a proper mod at this point - the features are not tied to any technology, there are a few known minor bugs and very little is configuration. However, it seems to be more than stable enough to use for my own games and to receive testing from other people, so here it is. At this time I am not expecting many people to notice it, and it is likely to stay in this testing form for some time. If you find it useful and want a non-debug version, let me know and I will add a quick option for that.

# Why write this when there are other logistic mods for trains?

Because I want something a little different from those mods, of course. Also because it's a fun problem to solve. 

What I want from this mod is something like the bot logistics in train form: A system that largely just works, staying out of your way and efficiently running trains on your network. I want to be able to design sprawling distributed bases where I can focus on problems of supply and demand, not complex loading and unloading problems (I mean, those problems are fun too - but I Want to have the *choice* about the abstraction level when I start a game).

# How do I use it?

Using the mod should be easy. To create an automated station, set up one to four filter inserters per wagon side to load/unload from the train. The filter inserters should be in whitelist mode, with empty filters. Connect the chests the inserters target with wire, and connect that wire to the station. Add a constant combinator, and connect it to the station *with a different coloured wire*.
If you set the new *P*rovider virtual signal, the station will automatically change its name to "SOURCE: " and then the symbols for whatever goods it can provide. If you set the *R*equester virtual signal, the station will automatically be renamed to "SINK: " and the symbols for whatever goods it has. To request items, set a negative amount of the good you want to be delivered. The negative number you choose will be used as a "minimum delivery" threshold - so, if you set -1000 copper plate, then the system will try to keep that station stocked with copper plate but never start a delivery of less than 1,000. 

You can set both Provide and Request on a station - it will change its name to "BUFFER: [etc]". I suspect that I will change this at some point to make it clear that it is still a sink station for the requested goods. Buffer stations do not really work like buffer chests (because a station can't easily load *and* unload the same resource), but they can provide one set of goods and request another. In particular, if you deliver filled barrels to one side of a station and provide the ability to load empty barrels on the other then (assuming you have connected both sets of chests to the station with the same wire and you set both Provide and Request on the other wire) the mod *will* use that station as both a sink of filled barrels and a source of empty ones.

## Why filter inserters?

Because the mod will automatically program the filters and inserter stack size to load or unload exact quantities of the goods you requested. This works for standard stack and filter inserters (and will probably work with some modded inserters, since it looks for any inserter with 'filter' in the name). There is no support for loaders or any other modded item mover.

## What about fluid wagons?

Just build the stations as usual. They should work.

## How do I tell the system to automate a train?

Create a (number of) station(s) named 'DEPOT'. Set the train to wait at the DEPOT station for inactivity. The code will automatically control any train that is waiting at a DEPOT station, and will send each automated train back to the DEPOT station after each delivery. You should ideally have one DEPOT station per train you want the mod to control.

# Why should I be interested?

If you want something more complex to use, or you want to care deeply about the loading/unloading stations, you probably shouldn't. But this mod does have a few interesting features:

## It uses a predictive demand model

The mod keeps track of delivery times and consumption rates for each requester station (using a weighted moving average). Assuming you have sufficient supply and your stations can load/unload fast enough, the mod should be able to automatically keep any station fully stocked no matter what the demand. 

## It tried to use the best train for each job

The mod prefers trains that are just large enough for the job. If a train already has some of a resource (from a failed job or other situation), it will be selected preferentially for a delivery of that resource.

## It can automatially load from multiple source stations

While the code prefers to load from a single source station, it can generate multi-station pickups where needed.

## It handles station naming for you, but you can still use your own names

Stations are autonmatically named for what they are doing. However, any part of a name after a # is preserved by the rename code. This allows something of a best-of-both-worlds approach, with functional names and custom identifiers.

# Okay, so what are the limitations?

## Currently, there's one item type per delivery

Once I have the bugs ironed out, I will add some code to combine deliveries. That needs the current code to be settled and reworked for clarity first, though.

## Sometimes, a delivery ends up leaving 4-8 of an item in the train

This is almost certainly an issue with the way the filter inserter programming is handled, probably something in the inserter stack size override code. It's basically harmless right now, since the filter programming ensures that "wrong" items should not be delivered, and a train with some stock will be used preferentially the next time there is a delivery of that resource.

## The mod does not have any code for handling a requester station running out of storage capacity

This should still fail safe - the delivery schedule includes a 5 second inactivity counter. If that triggers, the train will leave with some amount of stock still on board, and then likely deliver that to another station the next time there is need. Still, it would be nice to detect this happening and start calculating a "current maximum capacity" for each request stop.

## There are some enabled debug messages.

You will receive a debug message when a train is created, when stations are renamed, when a train goes astray, when a delivery is scheduled, etc.
You can also turn on debugging at a request stop - set the standard *D* signal and you will get a debug line per second for that stop. I usually turn it off immediately after receiving one message at present.

## There isn't enough feedback

I need to think about this. Possibly changing the colour of the station based on the situation.
