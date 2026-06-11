---@meta 'event'


---@class event
local event = {}

--- Register a new event listener that should be called for events with the specified name.
---@param event string the name of the event
---@param callbackFunction function the function to call when the event is triggered
---@return number the event id which can be canceled via event.cancel, if the event was successfully registered, false if this function was already registered for this event type.
function event.listen(event, callbackFunction) end


--- Unregister a previously registered event listener.
---@param event string the name of the event
---@param callbackFunction function the function that was to be called when the event was triggered
---@return true if the event was successfully unregistered, false if this function was not registered for this event type.
--- Note: An event listeners may return false to unregister themselves, which is equivalent to calling event.ignore and passing the listener with the event name it was registered for.
function event.ignore(event, callbackFunction) end

--- Starts a new timer that will be called after the time specified in interval.
--- Note: the timer resolution can vary. If the computer is idle and enters sleep mode, it will only be woken in a game tick, so the time the callback is called may be up to 0.05 seconds off.
---@param interval number the interval of the timer in seconds, can be a fraction
---@param callbackFunction function the function to call
---@param times number how many times the function will be called. If omitted the function will be called once. Pass 'math.huge' for infinite repeat.
---@return number timerId, the id used in event.cancel
function event.timer(interval, callbackFunction, times) end

--- Cancels a timer previously created with event.timer.
---@param timerId number id of the timer
---@return boolean true if the timer was cancelled, false if there was no timer with the specified id
function event.cancel(timerId) end

--- Pulls and returns the next available event from the queue, or waits until one becomes available.
---@param timeout number optional, if passed the function will wait for a new event for this many seconds at maximum then returns nil if no event was queued during that time.
---@param name string  an event pattern that will act as a filter. If given then only events that match this pattern will be returned. Can be nil in which case the event names will not be filtered. See string.match on how to use patterns.
---@param ... any any number of parameters in the same order as defined by the signal that is expected. Those arguments will act as filters for the additional arguments returned by the signal. Direct equality is used to determine if the argument is equal to the given filter. Can be nil in which case this particular argument will not be filtered.
function event.pull(timeout, name, ...) end

--- (Since 1.5.9) Pulls and returns the next available event from the queue, or waits until one becomes available but allows filtering by specifying filter function.
---@param timeout number optional, if passed the function will wait for a new event for this many seconds at maximum then returns nil if no event was queued during that time.
---@param filterFunction function if passed the function will use it as a filtering function of events. Allows for advanced filtering.
function event.pullFiltered(timeout, filterFunction) end


return event