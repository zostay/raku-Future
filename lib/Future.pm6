use v6;

class X::Future is Exception { }

my sub sigs(:$tried, :@found) {
    my $tried-sig = ":(" ~ @($tried).map({ .^name }).join(", ") ~ ")";
    my @found-sigs = @found.map({ .signature.gist });
    \(:$tried-sig, :@found-sigs);
}

class X::Future::NoMatch is X::Future {
    has $.handler;
    has $.tried;
    has @.found;

    method message(--> Str:D) {
        my (:$tried-sig, :@found-sigs) := sigs(:$!tried, :@!found);
        "Cannot resolve .$!handler() called with $tried-sig; none of these signatures match:\n"
            ~ join("\n", @found-sigs.map({ .indent(4) }))
    }
}

class X::Future::Ambiguous is X::Future {
    has $.handler;
    has $.tried;
    has @.found;

    method message(--> Str:D) {
        my (:$tried-sig, :@found-sigs) := sigs(:$!tried, :@!found);
        "Cannot resolve .$!handler() called with $tried-sig; these signatures all match:\n"
            ~ join("\n", @found-sigs.map({ .indent(4) }))
    }
}

class X::Future::Mismatch is X::Future {
    has $.expected;
    has $.got;

    method message(--> Str:D) {
        "Future[$!expected.^name()] type mismatch; expected $!expected.^name() but got $!got.^name()"
    }
}

my enum ValueStatus <Rejected Fulfilled>;

role Future[::Type = Any] {
    has Promise $!metal;

    method !get-metal() { $!metal }
    method !set-metal($metal) { $!metal = $metal }

    only method new(Future:) { die "Future.new cannot be used to create a Future." }

    method !new-future(Promise $p) {
        my $f = self.bless;
        $f!set-metal($p);
        $f
    }

    method awaitable(Future: $p --> Future:D) {
        my &promise-handler = self!make-promise-handler-into-future-handler({ await $p });

        my $f = self.bless;
        $f!set-metal(start { promise-handler() });
        $f
    }

    method immediate(Future: $v --> Future:D) {
        my $f = self.bless;
        my $p = Promise.new;
        $p.keep(\(Fulfilled, $v));
        $f!set-metal($p);
        $f;
    }

    method exceptional(Future: Exception $x --> Future:D) {
        my $f = self.bless;
        my $p = Promise.new;
        $p.keep(\(Rejected, $x));
        $f!set-metal($p);
        $f;
    }

    method is-pending(Future:D: --> Bool) { $!metal.status ~~ Planned }
    method is-rejected(Future:D: --> Bool) { !$.is-pending && !$.is-fulfilled }
    method is-fulfilled(Future:D: --> Bool) {
        $!metal.status ~~ Kept
            && $!metal.result[0] ~~ Fulfilled
            && $!metal.result[1] ~~ Type
    }

    method !make-promise-handler-into-future-handler(&handler) {
        anon sub future-handler(|c) {
            try {
                CATCH { default { return \(Rejected, $_) } }

                my $new-result = handler(|c);
                try {
                    my $c = \(|$new-result);
                    $new-result = await(|$c);
                }

                return \(Fulfilled, $new-result);
            }
        }
    }

    method !best-callable(@callbacks, $capture, :$handler) {
        # make sure the "capture" is a Capture
        my $c = \(|$capture);

        my @callable = @callbacks.grep({ $c ~~ &^cb.signature });
        if @callable == 0 {
            X::Future::NoMatch.new(
                :$handler, :tried($c), :found(@callbacks),
            ).throw;
        }
        elsif @callable > 1 {
            my @default = @callable.grep({ .?default });
            if @default == 1 {
                return @default[0];
            }
            else {
                X::Future::Ambiguous.new(
                    :$handler, :tried($c), :found(@callable),
                ).throw;
            }
        }
        else {
            return @callable[0];
        }
    }

    multi method then(Future:D: *@callbacks --> Future:D) {
        self!new-future(
            $!metal.then(sub ($p) {
                my $result = $p.result;
                if $result[0] ~~ Fulfilled {
                    try {
                        CATCH {
                            default {
                                return \(Rejected, $_);
                            }
                        }

                        my $c = \(|$result[1]);
                        my &callback = self!best-callable(@callbacks, $result[1], :handler<then>);
                        return .(|$c) with self!make-promise-handler-into-future-handler(&callback);
                    }
                }
                else {
                    return \(Rejected, $result[1]);
                }
            }),
        );
    }

    multi method catch(Future:D: *@callbacks --> Future:D) {
        self!new-future(
            $!metal.then(sub ($p) {
                my $result = $p.result;
                if $result[0] ~~ Rejected {
                    try {
                        CATCH {
                            default {
                                return \(Rejected, $_);
                            }
                        }

                        my $c = \($result[1]);
                        my &callback = self!best-callable(@callbacks, $result[1], :handler<catch>);
                        return .(|$c) with self!make-promise-handler-into-future-handler(&callback);
                    }
                }
                else {
                    return \(Fulfilled, $result[1]);
                }
            }),
        );
    }

    method last(Future:D: &callback --> Future:D) {
        self!new-future(
            $!metal.then(sub ($p) {
                my $result = $p.result;
                my $c = \(|$result[1]);
                try {
                    CATCH {
                        default {
                            return \(Rejected, $_);
                        }
                    }

                    callback(|$c);
                }

                return $result;
            }),
        );
    }

    method constrain(Future:D: Mu \type --> Future:D) {
        Future[type].new( metal => $!metal );
    }

    method result(Future:D: --> Mu) {
        my $result = $!metal.result;
        if $result[0] ~~ Fulfilled {
            my $v = $result[1];
            if $v ~~ Type {
                return $v;
            }
            else {
                X::Future::Mismatch.new(:expected(Type), :got($v)).throw;
            }
        }
        else {
            $result[1].rethrow;
        }
    }

    method start(Future: &code --> Future:D) {
        my &future-code = self!make-promise-handler-into-future-handler(&code);
        Future!new-future(start { future-code() });
    }
}

multi await(Future $future --> Mu) is export { $future.result }

=begin pod
=head1 NAME
Future - A futuristic extension to Promises and other awaitables
=head1 SYNOPSIS

    use Future;

    # Works like Promise.start({})
    my $f = Future.start: { long-running-process() };
    my $result = await $f;

    # Or from a Promise.new
    my $p = Promise.new;
    my $f = Future.from-promise($p);
    $p.keep(42);
    my $result = await $f;

    # But you can add types
    my Future[Int] $f .= start: { long-running-process() };
    my $result = await $f; # guaranteed to be an Int or throws exception
    CATCH { when X::Future::Mismatch { .say } }

    # And nested Futures automatically unravel nested Futures/Promises
    my $f = Future.start: {
        start { 42 }
    }
    say await $f; # prints 42, not Promise.new(...)

    # Callback chains have entirely different semantics from Promise
    # - catch() - allows you to handle exceptions
    # - then() - allows for asynchronous processing
    # - finally() - processing that is done regardless of outcome
    my Future[Int] $i = Future.start({ open('file.txt', :r) }).catch(
        -> X::IO { open('alt.txt', :r) }
    ).catch(
        -> X::IO { "42" }
    ).then(
        -> Str $val { $val.Numeric },
        -> IO::Handle $fh { $fh.slurp.Numeric },
    ).finally({ .say }).constrain(Int);

    say await $i;

=head1 DESCRIPTION

Promises are wonderful, but having become accustomed to some of the features of
Promises::Promise in Perl 5, I sometimes find the API of Promise to be lacking.
For many typical cases, these warts don't show up. For the edge cases, I wanted
to make something that made Promises a little nicer to work with. So to the
L<Future>.

A L<Future> is just a placeholder for a future value. It does not directly
provide any means of resolving that value. Instead, it depends on something else
to eventually provide that value:

=item The C<.start()> method takes a block which will run on a new thread. The
return value from the block becomes the future value.

=item The C<.awaitable()> method takes any object that can be used with
C<await>.  The Future will get the value of that object whenever C<await>
returns it.

=item The C<.immediate()> takes a value which immediately fulfills the Future.

=item The C<.exceptional()> takes an L<Exception>, which creates a rejected Future.

This means a Future can get its value from basically anything, including a
L<Promise>, L<Supply>, or L<Channel>.

A L<Future> provides asynchronous callbacks similar to those of L<Promise>.
These will be called when the future is fulfilled or rejected. This is different
from a L<Promise>, whose callbacks are only called when the Promise is kept. The
callbacks are executed using a form of multi-dispatch, so multiple alternative
callbacks can be provided and the callback chosen is based upon its signature.

The action of the callbacks is based on the method used to register them:

=item C<.then()> These callbacks are executed on fulfillment.

=item C<.catch()> These callbacks are executed on rejection.

=item C<.last()> These callbacks are executed on both fulfillment and
rejection.

Each of these return a new L<Future> that will be fulfilled after the original
Future is fulfilled and the callback completes.  The actual semantics of how
each these calls work is subtly different, but are loosely based upon the
differences in how Perl 6 handles multi-subs, CATCH-blocks, and LAST-blocks.

A L<Future> is also type-aware. I often want to return a L<Promise> from a
method, but then I have to explicitly document what that Promise is actually
supposed to return. This is no longer a problem with Future:

    # This is bleh
    method fib($n --> Promise) { ... }

    # This is nice
    method fib($n --> Future[Int]) { ... }

You can create a L<Future> with an explicitly parameterized type or you can use
the C<.constrain()> method to take an existing Future and apply that type
expectation. The latter should be done at the end of a callback chain because
it's only the final fulfillment that ought to be constrained to the final result
type. (Though, you may, of course, constrain the intermediate steps if you
like.)

Finally, a L<Future> will recursively await anything that is C<await>-able. All
concurrent objects built-in to Perl 6 provide an await function that can be used
to wait for a value from another thread to become available whtin the current
thread. This means that any time a Future encounters an object that can be
awaited, it will await that return before continuing.

=end pod
