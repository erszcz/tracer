# dbg:tracer/0 drop-in replacement

Tracing built into the Erlang VM is an enormously powerful mechanism,
both for troubleshooting live systems as well as visualising components
in development.

This is a tracer template which can be used as a drop-in replacement for `dbg:tracer()`.
Why? Sometimes it's convenient to truncate/reformat/omit some parts
of trace messages to get better clarity or more accurate traces.

Default dbg:dhandler/2 is nice,
but when you want to use domain knowledge or discard some of the data
(like too long arg lists or returned values)
it might be convenient to write your own dbg handler function.
However, this is error prone and since you can't trace your
trace function (d'oh!) it's hard to debug.

The way to go is to setup a monitor on the trace handler process.
When the trace function errors and kills the tracer process,
you'll be notified.
Still, if the monitor is setup by the shell, the 'DOWN' message
might simply end up in the message queue of the shell
and never be received - you won't know a crash happened.

So, it's best to setup a process which will monitor the trace handler
and print any 'DOWN' messages it receives.
This is be done in my\_tracer:start/0.

## Usage

Instead of:

```erlang
dbg:tracer().
dbg:p(all, [call, timestamp]).
dbg:tpl(mod_reauth, set_timer_for_new_session, x).
```

Do:

```erlang
code:add_path("/Users/erszcz/work/erszcz/tracer").
my_tracer:start().
dbg:p(all, [call, timestamp]).
dbg:tpl(mod_reauth, set_timer_for_new_session, x).
```

The rest (i.e. filtering/formatting traces) is up to you.
Open `my_tracer.erl` in your editor and hack away!
