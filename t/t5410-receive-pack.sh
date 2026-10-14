#!/bin/sh

test_description='git receive-pack'

GIT_TEST_DEFAULT_INITIAL_BRANCH_NAME=main
export GIT_TEST_DEFAULT_INITIAL_BRANCH_NAME

. ./test-lib.sh

test_expect_success 'setup' '
	test_commit base &&
	git clone -s --bare . fork &&
	git checkout -b public/branch main &&
	test_commit public &&
	git checkout -b private/branch main &&
	test_commit private
'

extract_haves () {
	depacketize | sed -n 's/^\([^ ][^ ]*\) \.have/\1/p'
}

test_expect_success 'with core.alternateRefsCommand' '
	write_script fork/alternate-refs <<-\EOF &&
		git --git-dir="$1" for-each-ref \
			--format="%(objectname)" \
			refs/heads/public/
	EOF
	test_config -C fork core.alternateRefsCommand ./alternate-refs &&
	git rev-parse public/branch >expect &&
	printf "0000" | git receive-pack fork >actual &&
	extract_haves <actual >actual.haves &&
	test_cmp expect actual.haves
'

test_expect_success 'with core.alternateRefsPrefixes' '
	test_config -C fork core.alternateRefsPrefixes "refs/heads/private" &&
	git rev-parse private/branch >expect &&
	printf "0000" | git receive-pack fork >actual &&
	extract_haves <actual >actual.haves &&
	test_cmp expect actual.haves
'

# The `tee.exe` shipped in Git for Windows v2.49.0 is known to hang frequently
# when spawned from `git.exe` and piping its output to `git.exe`. This seems
# related to MSYS2 runtime bug fixes regarding the signal handling; Let's just
# skip the tests that need to exercise this when the faulty MSYS2 runtime is
# detected; The test cases are exercised enough in other matrix jobs of the CI
# runs.
test_lazy_prereq TEE_DOES_NOT_HANG '
	test_have_prereq !MINGW &&
	case "$(uname -a)" in *3.5.7-463ebcdc.x86_64*) false;; esac
'

test_expect_success TEE_DOES_NOT_HANG \
	'receive-pack missing objects fails connectivity check' '
	test_when_finished rm -rf repo remote.git setup.git &&

	git init repo &&
	git -C repo commit --allow-empty -m 1 &&
	git clone --bare repo setup.git &&
	git -C repo commit --allow-empty -m 2 &&

	# Capture git-send-pack(1) output sent to git-receive-pack(1).
	git -C repo send-pack ../setup.git --all \
		--receive-pack="tee ${SQ}$(pwd)/out${SQ} | git-receive-pack" &&

	# Replay captured git-send-pack(1) output on new empty repository.
	git init --bare remote.git &&
	git receive-pack remote.git <out >actual 2>err &&

	test_grep "missing necessary objects" actual &&
	test_grep "fatal: Failed to traverse parents" err &&
	test_must_fail git -C remote.git cat-file -e $(git -C repo rev-parse HEAD)
'

test_expect_success TEE_DOES_NOT_HANG \
	'receive-pack missing objects bypasses connectivity check' '
	test_when_finished rm -rf repo remote.git setup.git &&

	git init repo &&
	git -C repo commit --allow-empty -m 1 &&
	git clone --bare repo setup.git &&
	git -C repo commit --allow-empty -m 2 &&

	# Capture git-send-pack(1) output sent to git-receive-pack(1).
	git -C repo send-pack ../setup.git --all \
		--receive-pack="tee ${SQ}$(pwd)/out${SQ} | git-receive-pack" &&

	# Replay captured git-send-pack(1) output on new empty repository.
	git init --bare remote.git &&
	git receive-pack --skip-connectivity-check remote.git <out >actual 2>err &&

	test_grep ! "missing necessary objects" actual &&
	test_must_be_empty err &&
	git -C remote.git cat-file -e $(git -C repo rev-parse HEAD) &&
	test_must_fail git -C remote.git rev-list $(git -C repo rev-parse HEAD)
'

test_expect_success 'explicit-haves does not infer haves from named refs' '
	test_when_finished "rm -rf explicit-haves-*" &&

	git init explicit-haves-src &&
	test_commit -C explicit-haves-src B &&
	git init --bare explicit-haves-base.git &&
	git -C explicit-haves-src push ../explicit-haves-base.git \
		B:refs/heads/main &&
	test_commit -C explicit-haves-src F1 &&
	test_commit -C explicit-haves-src F2 &&
	git -C explicit-haves-src reset --hard F1 &&
	test_commit -C explicit-haves-src F3 &&
	B=$(git -C explicit-haves-src rev-parse B) &&
	F1=$(git -C explicit-haves-src rev-parse F1) &&
	F2=$(git -C explicit-haves-src rev-parse F2) &&
	git clone --bare --shared explicit-haves-base.git \
		explicit-haves-remote.git &&
	git -C explicit-haves-remote.git update-ref -d refs/heads/main &&
	old_pack=$(printf "F2\n^B\n" | \
		git -C explicit-haves-src pack-objects --revs \
		../explicit-haves-remote.git/objects/pack/old) &&
	git -C explicit-haves-remote.git update-ref \
		refs/heads/feature "$F2" &&
	git -C explicit-haves-remote.git update-ref \
		refs/heads/unchanged "$F2" &&
	git -C explicit-haves-remote.git config receive.unpackLimit 0 &&
	git -C explicit-haves-remote.git config maintenance.auto false &&

	# The advertised ref is still used to reject a stale lease.
	test_must_fail git -C explicit-haves-src push --no-thin \
		--force-with-lease=refs/heads/feature:$F1 \
		--receive-pack="git receive-pack --advertise-explicit-haves-for-testing" \
		../explicit-haves-remote.git F3:refs/heads/feature \
		2>explicit-haves-stale.err &&
	test_grep "stale info" explicit-haves-stale.err &&

	# With the capability, only B is negative and only F3 is positive.
	# The new pack is complete after replacing the old F2 pack.
	rcvpck="unset GIT_TRACE_PACKET GIT_TRACE2_EVENT; git receive-pack --advertise-explicit-haves-for-testing" &&
	GIT_TRACE_PACKET="$(pwd)/explicit-haves.trace" \
	GIT_TRACE2_EVENT="$(pwd)/explicit-haves.event" \
	git -C explicit-haves-src push --no-thin \
		--force-with-lease=refs/heads/feature:$F2 \
		--receive-pack="$rcvpck" \
		../explicit-haves-remote.git F3:refs/heads/feature \
		F2:refs/heads/unchanged &&
	test_grep "push< $B \\.have" explicit-haves.trace &&
	test_grep "push> .* explicit-haves" explicit-haves.trace &&
	test_grep "write_pack_file/wrote.*\"value\":\"6\"" \
		explicit-haves.event &&
	git -C explicit-haves-remote.git update-ref -d \
		refs/heads/unchanged &&
	rm explicit-haves-remote.git/objects/pack/old-"$old_pack".pack \
		explicit-haves-remote.git/objects/pack/old-"$old_pack".idx &&
	git -C explicit-haves-remote.git fsck --full
'

test_expect_success 'setup Pando exact-old capability tests' '
	git init pando-src &&
	test_commit -C pando-src one &&
	test_commit -C pando-src two &&
	git init --bare pando-remote.git &&
	pando_one=$(git -C pando-src rev-parse one) &&
	pando_two=$(git -C pando-src rev-parse two) &&
	pando_receive_pack="unset GIT_TRACE_PACKET GIT_TRACE2_EVENT; git receive-pack" &&
	pando_both="$pando_receive_pack --advertise-explicit-haves-for-testing" &&
	pando_both="$pando_both --advertise-pando-exact-old-oid-v1-for-testing"
'

test_expect_success 'required Pando capability rejects either missing capability before sending' '
	for advertised in none explicit-haves pando-exact-old-oid-v1
	do
		case "$advertised" in
		none) advertise_option= ;;
		*) advertise_option="--advertise-$advertised-for-testing" ;;
		esac &&
		test_env GIT_TRACE_PACKET="$(pwd)/pando-$advertised.trace" \
		GIT_TRACE2_EVENT="$(pwd)/pando-$advertised.event" \
		test_must_fail git -C pando-src push \
			--require-pando-exact-old-oid-v1 \
			--force-with-lease=refs/heads/target: \
			--receive-pack="$pando_receive_pack $advertise_option" \
			../pando-remote.git one:refs/heads/target \
			2>pando-$advertised.err || return 1
		test_grep "the receiving end does not support --require-pando-exact-old-oid-v1" \
			pando-$advertised.err || return 1
		test_grep ! "push> .* refs/heads/target" pando-$advertised.trace || return 1
		test_grep ! "pack-objects" pando-$advertised.event || return 1
		test_must_fail git -C pando-remote.git show-ref --verify \
			refs/heads/target || return 1
	done
'

test_expect_success 'required Pando capability sends exact create and update old OIDs' '
	GIT_TRACE_PACKET="$(pwd)/pando-create.trace" \
	git -C pando-src push --require-pando-exact-old-oid-v1 \
		--force-with-lease=refs/heads/target: \
		--receive-pack="$pando_both" \
		../pando-remote.git one:refs/heads/target &&
	test_grep "push> $ZERO_OID $pando_one refs/heads/target.* explicit-haves" \
		pando-create.trace &&
	test_grep "push> $ZERO_OID $pando_one refs/heads/target.* pando-exact-old-oid-v1" \
		pando-create.trace &&
	GIT_TRACE_PACKET="$(pwd)/pando-update.trace" \
	git -C pando-src push --require-pando-exact-old-oid-v1 \
		--force-with-lease=refs/heads/target:$pando_one \
		--receive-pack="$pando_both" \
		../pando-remote.git two:refs/heads/target &&
	test_grep "push> $pando_one $pando_two refs/heads/target.* explicit-haves" \
		pando-update.trace &&
	test_grep "push> $pando_one $pando_two refs/heads/target.* pando-exact-old-oid-v1" \
		pando-update.trace &&
	echo "$pando_two" >expect &&
	git -C pando-remote.git rev-parse refs/heads/target >actual &&
	test_cmp expect actual
'

test_expect_success 'Pando exact-old capability remains opt-in' '
	GIT_TRACE_PACKET="$(pwd)/pando-default.trace" \
	git -C pando-src push --receive-pack="$pando_both" \
		../pando-remote.git one:refs/heads/default &&
	test_grep "push> .* refs/heads/default.* explicit-haves" pando-default.trace &&
	test_grep ! "push> .* pando-exact-old-oid-v1" pando-default.trace
'

test_done
