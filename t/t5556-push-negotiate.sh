#!/bin/sh

test_description='required negotiation before constructing a push pack'

GIT_TEST_DEFAULT_INITIAL_BRANCH_NAME=main
export GIT_TEST_DEFAULT_INITIAL_BRANCH_NAME

. ./test-lib.sh

setup_push () {
	test_when_finished "rm -rf client server" &&
	git init client &&
	test_commit -C client base &&
	test_commit -C client tip &&
	git init --bare server &&
	git -C client remote add origin ../server
}

setup_common () {
	setup_push &&
	git -C client push origin base:refs/heads/base &&
	git -C server config receive.hideRefs refs/heads/base
}

check_no_pack () {
	test_grep ! "pack-objects" trace &&
	test_grep ! "proceeding anyway" err &&
	test_must_fail git -C server show-ref --verify refs/heads/main
}

for mode in true required
do
	test_expect_success "push.negotiate=$mode finds hidden common history" '
		setup_common &&
		test_when_finished "rm -f trace" &&
		GIT_TRACE2_EVENT="$PWD/trace" \
			git -C client -c protocol.version=2 -c push.negotiate=$mode \
			push origin main &&
		test_grep "write_pack_file/wrote.*\"value\":\"3\"" trace &&
		git -C client rev-parse main >expect &&
		git -C server rev-parse main >actual &&
		test_cmp expect actual
	'
done

test_expect_success 'required negotiation can succeed without a common commit' '
	setup_push &&
	test_when_finished "rm -f trace packet" &&
	GIT_TRACE2_EVENT="$PWD/trace" GIT_TRACE_PACKET="$PWD/packet" \
		git -C client -c protocol.version=2 -c push.negotiate=required \
		push origin main &&
	test_grep "fetch< NAK" packet &&
	test_grep ! "fetch< ACK" packet &&
	test_grep "write_pack_file/wrote.*\"value\":\"6\"" trace &&
	git -C client rev-parse main >expect &&
	git -C server rev-parse main >actual &&
	test_cmp expect actual
'

for version in 0 1
do
	test_expect_success "required negotiation rejects protocol v$version before packing" '
		setup_common &&
		test_when_finished "rm -f trace" &&
		test_must_fail env GIT_TRACE2_EVENT="$PWD/trace" \
			git -C client -c protocol.version=$version \
			-c push.negotiate=required push origin main 2>err &&
		test_grep "requires protocol v2" err &&
		test_grep "push negotiation failed; aborting push" err &&
		check_no_pack
	'
done

for mode in true false
do
	test_expect_success "explicit push.negotiate=$mode overrides required" '
		setup_common &&
		test_config -C client push.negotiate required &&
		test_when_finished "rm -f trace" &&
		GIT_TRACE2_EVENT="$PWD/trace" \
			git -C client -c protocol.version=0 -c push.negotiate=$mode \
			push origin main 2>err &&
		test_grep "write_pack_file/wrote.*\"value\":\"6\"" trace &&
		if test "$mode" = true
		then
			test_grep "push negotiation failed; proceeding anyway" err
		else
			test_grep ! "push negotiation failed" err
		fi
	'
done

test_expect_success 'push.negotiate preserves boolean spellings' '
	setup_common &&
	for mode in yes on 1 no off 0 ""
	do
		git -C client -c push.negotiate="$mode" \
			push --dry-run origin main || return 1
	done &&
	git -C client -c push.negotiate push --dry-run origin main
'

test_expect_success 'invalid push.negotiate fails before packing' '
	setup_common &&
	test_when_finished "rm -f trace" &&
	test_must_fail env GIT_TRACE2_EVENT="$PWD/trace" \
		git -C client -c push.negotiate=invalid push origin main 2>err &&
	test_grep "bad boolean config value" err &&
	check_no_pack
'

test_expect_success 'deletion-only push does not require negotiation' '
	setup_common &&
	git -C server config --unset receive.hideRefs &&
	test_when_finished "rm -f trace" &&
	GIT_TRACE2_EVENT="$PWD/trace" \
		git -C client -c protocol.version=0 -c push.negotiate=required \
		push origin :base &&
	test_grep ! "negotiate-only" trace &&
	test_grep ! "pack-objects" trace &&
	test_must_fail git -C server show-ref --verify refs/heads/base
'

setup_ssh_push () {
	setup_common &&
	write_script ssh-wrapper <<-\EOF &&
	if test "$1" = -o
	then
		shift 2
	fi
	shift
	case "$1" in
	git-upload-pack*) exec "$NEGOTIATION_SCRIPT" ;;
	*) exec sh -c "$1" ;;
	esac
	EOF
	test_config -C client remote.origin.url "testhost:$PWD/server" &&
	test_config -C client ssh.variant ssh
}

test_expect_success 'required negotiation stops on transport failure' '
	setup_ssh_push &&
	write_script failed-upload-pack <<-\EOF &&
	exit 1
	EOF
	test_when_finished "rm -f trace" &&
	test_must_fail env GIT_TRACE2_EVENT="$PWD/trace" \
		GIT_SSH="$PWD/ssh-wrapper" \
		NEGOTIATION_SCRIPT="$PWD/failed-upload-pack" \
		git -C client -c push.negotiate=required push origin main 2>err &&
	test_grep "Could not read from remote repository" err &&
	test_grep "push negotiation failed; aborting push" err &&
	check_no_pack
'

test_expect_success !MINGW 'required negotiation stops when negotiation is interrupted' '
	setup_ssh_push &&
	write_script interrupted-upload-pack <<-\EOF &&
	# GIT_SSH executes this script directly, so its parent is fetch.
	kill -TERM "$PPID"
	EOF
	test_when_finished "rm -f trace" &&
	test_must_fail env GIT_TRACE2_EVENT="$PWD/trace" \
		GIT_SSH="$PWD/ssh-wrapper" \
		NEGOTIATION_SCRIPT="$PWD/interrupted-upload-pack" \
		git -C client -c push.negotiate=required push origin main 2>err &&
	test_grep "\"code\":143" trace &&
	test_grep "push negotiation failed; aborting push" err &&
	check_no_pack
'

test_done
