#!/usr/bin/env perl6
use v6;

use Test;
use Future;

dies-ok { Future.new };
lives-ok { Promise.new };

subtest 'Future' => {
    my $f = Future.start: { 42 };
    does-ok $f, Future;
    is await($f), 42;
    is $f.result, 42;
    nok $f.is-pending;
    ok $f.is-fulfilled;
    nok $f.is-rejected;
}

subtest 'Promise to Future' => {
    my $p = Promise.new;
    isa-ok $p, Promise;

    my $f = Future.await($p);
    does-ok $f, Future;
}

done-testing;
