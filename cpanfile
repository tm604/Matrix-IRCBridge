requires 'parent', 0;
requires 'Future', '>= 0.29';
requires 'Net::Async::IRC', 0;
requires 'Net::Async::Matrix', '>= 0.05';
requires 'IO::Async', '>= 0.63';

on 'test' => sub {
	requires 'Test::More', '>= 0.98';
};

