#!../../src/liquidsoap ../../libs/stdlib.liq ../../libs/deprecations.liq

# Basic request tests

%include "test.liq"

settings.log.level.set(4)

def next() =
  [request.create("file1.mp3")]
end

r = request.dynamic.list(prefetch=1, next)

output.dummy(fallible=true, r)

def f() =
  if not r.is_ready() then
    0.1
  else
    if not r.add(request.create("file2.mp3")) then
      test.fail()
    end

    r.set_queue([
      request.create("file2.mp3"),
      request.create("file3.mp3")
    ])
  
    q = r.queue()

    if list.length(q) != 2 then
      test.fail()
    end

    c = r.current()

    if not null.defined(c) then
      test.fail()
    end

    c = null.get(c)
    if request.filename(c) != "file1.mp3" then
      test.fail()
    end

    test.pass()

    (-1.)
  end
end

thread.run.recurrent(f)