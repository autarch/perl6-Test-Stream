use v6;
use lib 'lib', 't/lib';

use My::Test;
use Test::Stream::Event;
use Test::Stream::Hub;
use Test::Stream::Recorder;

my-subtest 'multiple listeners and events', {
    my $hub = Test::Stream::Hub.new;

    my $l1 = Test::Stream::Recorder.new;
    my $l2 = Test::Stream::Recorder.new;
    $hub.add-listener($l1);
    $hub.add-listener($l2);

    my-throws-like(
        { $hub.start-suite( name => 'suite' ) },
        rx{ 'Attempted to send a Test::Stream::Event::Suite::Start event before any context was set' },
        'cannot start a suite without a context'
    );

    $hub.set-context;
    LEAVE { $hub.release-context; }

    $hub.start-suite( name => 'suite' );

    my-is(
        $l1.events.elems, 1,
        'first listener got 1 event',
    );
    my-is(
        $l2.events.elems, 1,
        'second listener got 1 event',
    );

    $hub.send-event(
        Test::Stream::Event::Diag.new(
            message => 'blah',
        )
    );

    $hub.end-suite( name => 'suite' );

    my-is(
        $l1.events.elems, 3,
        'first listener got 3 events',
    );
    my-is(
        $l2.events.elems, 3,
        'second listener got 3 events',
    );

    for < Suite::Start Diag Suite::End >.kv -> $i, $type {
        my-is(
            $l1.events[$i].type, $type,
            "first listener event #$i is a $type",
        );
        my-is(
            $l2.events[$i].type, $type,
            "second listener event #$i is a $type",
        );
    }

    $hub.remove-listener($l2);

    my-is(
        $hub.listeners.elems, 1,
        'hub has one listener after calling remove-listener'
    );
    my-is(
        $hub.listeners[0], $l1,
        'the remaining listener is the one that was not removed'
    );

};

my-subtest 'errors from bad event sequences', {
    my $hub = Test::Stream::Hub.new;
    my $l = Test::Stream::Recorder.new;

    $hub.add-listener($l);

    $hub.set-context;
    LEAVE { $hub.release-context; }

    my-throws-like(
        {
            $hub.send-event(
                Test::Stream::Event::Plan.new(
                    planned => 42,
                )
            )
        },
        rx{ 'Attempted to send a Test::Stream::Event::Plan event before any suites were started' },
        'got exception trying to send a plan before starting a suite'
    );

    my-throws-like(
        { $hub.end-suite( name => 'random-suite' ) },
        rx{ 'Attempted to end a suite (random-suite) before any suites were started' },
        'got exception trying to end a suite before any suites were started'
    );

    $hub.start-suite( name => 'top' );
    test-event-stream(
        $l,
        ${
            class      => Test::Stream::Event::Suite::Start,
            attributes => ${
                name => 'top',
            },
        },
    );

    $hub.start-suite( name => 'depth 1' );
    test-event-stream(
        $l,
        ${
            class      => Test::Stream::Event::Suite::Start,
            attributes => ${
                name => 'depth 1',
            },
        },
    );

    my-throws-like(
        { $hub.end-suite( name => 'random-suite' ) },
        rx{ 'Attempted to end a suite (random-suite) that is not the currently running suite (depth 1)' },
        'got exception trying to end a suite that does not match the last suite started (depth of 2)'
    );

    $hub.send-event(
        Test::Stream::Event::Test.new(
            passed => True,
        )
    );
    test-event-stream(
        $l,
        ${
            class      => Test::Stream::Event::Test,
            attributes => ${
                passed => True,
            },
        },
    );

    $hub.end-suite( name => 'depth 1' );
    test-event-stream(
        $l,
        ${
            class      => Test::Stream::Event::Suite::End,
            attributes => ${
                name          => 'depth 1',
                tests-planned => (Int),
                tests-run     => 1,
                tests-failed  => 0,
                passed        => True,
            },
        },
    );

    my-throws-like(
        { $hub.end-suite( name => 'random-suite' ) },
        rx{ 'Attempted to end a suite (random-suite) that is not the currently running suite (top)' },
        'got exception trying to end a suite that does not match the last suite started (depth of 1)'
    );

    $hub.end-suite( name => 'top' );
    test-event-stream(
        $l,
        ${
            class      => Test::Stream::Event::Suite::End,
            attributes => ${
                name          => 'top',
                tests-planned => (Int),
                tests-run     => 1,
                tests-failed  => 0,
                passed        => True,
            },
        },
    );
};

my-subtest 'events after Bail', {
    my $hub = Test::Stream::Hub.new;
    $hub.add-listener(Test::Stream::Recorder.new);

    $hub.set-context;
    LEAVE { $hub.release-context; }

    $hub.start-suite( name => 'suite' );
    $hub.send-event(
        Test::Stream::Event::Test.new(
            passed => True,
        )
    );
    $hub.send-event( Test::Stream::Event::Bail.new );

    my-throws-like(
        {
            $hub.send-event(
                Test::Stream::Event::Test.new(
                    passed => True,
                )
            );
        },
        rx{ 'Attempted to send a Test::Stream::Event::Test event after sending a Bail' },
        'error from sending Test event after Bail'
    );

    my-lives-ok(
        { $hub.end-suite( name => 'suite' ) },
        'ending suite after Bail is ok'
    );
};

my-subtest 'finalize when Bail is seen', {
    my $hub = Test::Stream::Hub.new;
    $hub.add-listener(Test::Stream::Recorder.new);

    $hub.set-context;
    LEAVE { $hub.release-context; }

    $hub.start-suite( name => 'suite' );
    $hub.send-event(
        Test::Stream::Event::Test.new(
            passed => True,
        )
    ) for 1..10;
    $hub.send-event(
        Test::Stream::Event::Test.new(
            passed => False,
        )
    ) for 1..3;
    $hub.send-event(
        Test::Stream::Event::Bail.new(
            reason => 'computer is on fire',
        )
    );
    $hub.end-suite( name => 'suite' );

    my $status = $hub.finalize;
    my-is(
        $status.exit-code,
        255,
        'status exit-code is 255'
    );
    my-is(
        $status.error,
        'Bailed out - computer is on fire',
        'status has expected error'
    );
};

my-subtest 'finalize when 3 tests fail', {
    my $hub = Test::Stream::Hub.new;
    $hub.add-listener(Test::Stream::Recorder.new);

    $hub.set-context;
    LEAVE { $hub.release-context; }

    $hub.start-suite( name => 'suite' );
    $hub.send-event(
        Test::Stream::Event::Test.new(
            passed => True,
        )
    ) for 1..10;
    $hub.send-event(
        Test::Stream::Event::Test.new(
            passed => False,
        )
    ) for 1..3;
    $hub.end-suite( name => 'suite' );

    $hub.set-context;
    LEAVE { $hub.release-context; }

    my $status = $hub.finalize;
    my-is(
        $status.exit-code,
        3,
        'status exit-code is 3'
    );
    my-is(
        $status.error,
        'failed 3 tests',
        'status has expected error'
    );
};

my-subtest 'finalize when plan does not match tests run', {
    my $hub = Test::Stream::Hub.new;
    $hub.add-listener(Test::Stream::Recorder.new);

    $hub.set-context;
    LEAVE { $hub.release-context; }

    $hub.start-suite( name => 'suite' );
    $hub.send-event(
        Test::Stream::Event::Plan.new(
            planned => 2,
        )
    );
    $hub.send-event(
        Test::Stream::Event::Test.new(
            passed => True,
        )
    );
    $hub.end-suite( name => 'suite' );

    my $status = $hub.finalize;
    my-is(
        $status.exit-code,
        255,
        'status exit-code is 255'
    );
    my-is(
        $status.error,
        'planned 2 tests but ran 1 test',
        'status has expected error'
    );
};

my-subtest 'finalize when 2 child suites are unfinished', {
    my $hub = Test::Stream::Hub.new;
    $hub.add-listener(Test::Stream::Recorder.new);

    $hub.set-context;
    LEAVE { $hub.release-context; }

    $hub.start-suite( name => 'suite' );
    $hub.start-suite( name => 'inner1' );
    $hub.start-suite( name => 'inner2' );
    $hub.send-event(
        Test::Stream::Event::Test.new(
            passed => True,
        )
    );

    my $status = $hub.finalize;
    my-is(
        $status.exit-code,
        1,
        'status exit-code is 1'
    );
    my-is(
        $status.error,
        'finalize was called but 3 suites are still in process',
        'status has expected error'
    );
};

my-subtest 'finalize when all tests pass', {
    my $hub = Test::Stream::Hub.new;
    $hub.add-listener(Test::Stream::Recorder.new);

    $hub.set-context;
    LEAVE { $hub.release-context; }

    $hub.start-suite( name => 'suite' );
    $hub.send-event(
        Test::Stream::Event::Test.new(
            passed => True,
        )
    );
    $hub.end-suite( name => 'suite' );

    my $status = $hub.finalize;
    my-is(
        $status.exit-code,
        0,
        'status exit-code is 0'
    );
    my-is(
        $status.error,
        q{},
        'status has no error'
    );
};

my-subtest 'starting a suite without any listeners', {
    my $hub = Test::Stream::Hub.new;

    $hub.set-context;
    LEAVE { $hub.release-context; }

    my-throws-like(
        { $hub.start-suite( name => 'whatever' ) },
        rx{ 'Attempted to send a Test::Stream::Event::Suite::Start event before any listeners were added' },
        'got exception trying to start a suite without any listeners added'
    );
};

my-subtest 'instance returns the same object', {
    my $hub = Test::Stream::Hub.instance;

    my-is(
        $hub, Test::Stream::Hub.instance,
        'instance always returns the same object'
    );
};

my-done-testing;
