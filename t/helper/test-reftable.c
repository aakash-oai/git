#include "git-compat-util.h"
#include "hash.h"
#include "hex.h"
#include "reftable/system.h"
#include "reftable/blocksource.h"
#include "reftable/stack.h"
#include "reftable/table.h"
#include "strbuf.h"
#include "reftable/reftable-constants.h"
#include "reftable/reftable-error.h"
#include "reftable/reftable-merged.h"
#include "reftable/reftable-stack.h"
#include "reftable/reftable-table.h"
#include "test-tool.h"

static void print_help(void)
{
	printf("usage: dump [-st] arg\n\n"
	       "options: \n"
	       "  -b dump blocks\n"
	       "  -t dump table\n"
	       "  -s dump stack\n"
	       "  -6 sha256 hash format\n"
	       "  -h this help\n"
	       "\n");
}

static int dump_blocks(const char *tablename)
{
	struct reftable_table_iterator ti = { 0 };
	struct reftable_block_source src = { 0 };
	struct reftable_table *table = NULL;
	uint8_t section_type = 0;
	int err;

	err = reftable_block_source_from_file(&src, tablename);
	if (err < 0)
		goto done;

	err = reftable_table_new(&table, &src, tablename);
	if (err < 0)
		goto done;

	err = reftable_table_iterator_init(&ti, table);
	if (err < 0)
		goto done;

	printf("header:\n");
	printf("  block_size: %d\n", table->block_size);

	while (1) {
		const struct reftable_block *block;

		err = reftable_table_iterator_next(&ti, &block);
		if (err < 0)
			goto done;
		if (err > 0)
			break;

		if (block->block_type != section_type) {
			const char *section;
			switch (block->block_type) {
			case REFTABLE_BLOCK_TYPE_LOG:
				section = "log";
				break;
			case REFTABLE_BLOCK_TYPE_REF:
				section = "ref";
				break;
			case REFTABLE_BLOCK_TYPE_OBJ:
				section = "obj";
				break;
			case REFTABLE_BLOCK_TYPE_INDEX:
				section = "idx";
				break;
			default:
				err = -1;
				goto done;
			}

			section_type = block->block_type;
			printf("%s:\n", section);
		}

		printf("  - length: %u\n", block->restart_off);
		printf("    restarts: %u\n", block->restart_count);
	}

done:
	reftable_table_iterator_release(&ti);
	reftable_table_decref(table);
	return err;
}

static int dump_table(struct reftable_merged_table *mt)
{
	struct reftable_iterator it = { NULL };
	struct reftable_ref_record ref = { NULL };
	struct reftable_log_record log = { NULL };
	const struct git_hash_algo *algop;
	int err;

	err = reftable_merged_table_init_ref_iterator(mt, &it);
	if (err < 0)
		return err;

	err = reftable_iterator_seek_ref(&it, "");
	if (err < 0)
		return err;

	algop = &hash_algos[hash_algo_by_id(reftable_merged_table_hash_id(mt))];

	while (1) {
		err = reftable_iterator_next_ref(&it, &ref);
		if (err > 0)
			break;
		if (err < 0)
			return err;

		printf("ref{%s(%" PRIu64 ") ", ref.refname, ref.update_index);
		switch (ref.value_type) {
		case REFTABLE_REF_SYMREF:
			printf("=> %s", ref.value.symref);
			break;
		case REFTABLE_REF_VAL2:
			printf("val 2 %s", hash_to_hex_algop(ref.value.val2.value, algop));
			printf("(T %s)", hash_to_hex_algop(ref.value.val2.target_value, algop));
			break;
		case REFTABLE_REF_VAL1:
			printf("val 1 %s", hash_to_hex_algop(ref.value.val1, algop));
			break;
		case REFTABLE_REF_DELETION:
			printf("delete");
			break;
		}
		printf("}\n");
	}
	reftable_iterator_destroy(&it);
	reftable_ref_record_release(&ref);

	err = reftable_merged_table_init_log_iterator(mt, &it);
	if (err < 0)
		return err;

	err = reftable_iterator_seek_log(&it, "");
	if (err < 0)
		return err;

	while (1) {
		err = reftable_iterator_next_log(&it, &log);
		if (err > 0)
			break;
		if (err < 0)
			return err;

		switch (log.value_type) {
		case REFTABLE_LOG_DELETION:
			printf("log{%s(%" PRIu64 ") delete\n", log.refname,
			       log.update_index);
			break;
		case REFTABLE_LOG_UPDATE:
			printf("log{%s(%" PRIu64 ") %s <%s> %" PRIu64 " %04d\n",
			       log.refname, log.update_index,
			       log.value.update.name ? log.value.update.name : "",
			       log.value.update.email ? log.value.update.email : "",
			       log.value.update.time,
			       log.value.update.tz_offset);
			printf("%s => ", hash_to_hex_algop(log.value.update.old_hash, algop));
			printf("%s\n\n%s\n}\n", hash_to_hex_algop(log.value.update.new_hash, algop),
			       log.value.update.message ? log.value.update.message : "");
			break;
		}
	}
	reftable_iterator_destroy(&it);
	reftable_log_record_release(&log);
	return 0;
}

static int dump_stack(const char *stackdir, uint32_t hash_id)
{
	struct reftable_stack *stack = NULL;
	struct reftable_stack_options opts = { .hash_id = hash_id };
	struct reftable_merged_table *merged = NULL;

	int err = reftable_new_stack(&stack, stackdir, &opts);
	if (err < 0)
		goto done;

	merged = reftable_stack_merged_table(stack);
	err = dump_table(merged);
done:
	if (stack)
		reftable_stack_destroy(stack);
	return err;
}

static int dump_reftable(const char *tablename)
{
	struct reftable_block_source src = { 0 };
	struct reftable_merged_table *mt = NULL;
	struct reftable_table *table = NULL;
	int err;

	err = reftable_block_source_from_file(&src, tablename);
	if (err < 0)
		goto done;

	err = reftable_table_new(&table, &src, tablename);
	if (err < 0)
		goto done;

	err = reftable_merged_table_new(&mt, &table, 1,
					reftable_table_hash_id(table));
	if (err < 0)
		goto done;

	err = dump_table(mt);

done:
	reftable_merged_table_free(mt);
	reftable_table_decref(table);
	return err;
}

static int characterize_deleted_file(const char *path)
{
	struct reftable_block_source src = { 0 };
	struct reftable_mmap map = { 0 };
	struct stat st;
	int held_fd, fd, open_errno, err;

	held_fd = open(path, O_RDONLY);
	if (held_fd < 0 || fstat(held_fd, &st) < 0)
		die_errno("cannot open file to delete");
	if (unlink(path))
		die_errno("cannot delete open file");

	fd = open(path, O_RDONLY);
	open_errno = errno;
	printf("open deleted file: %s\n", fd < 0 && open_errno == ENOENT ?
	       "ENOENT" : fd < 0 && open_errno == EACCES ? "EACCES" : "other");
	if (fd >= 0)
		close(fd);

	err = reftable_block_source_from_file(&src, path);
	printf("block source: %d\n", err);
	block_source_close(&src);

	err = reftable_mmap(&map, held_fd, st.st_size);
	printf("map deleted file: %d\n", err);
	if (!err)
		reftable_munmap(&map);
	close(held_fd);
	return 0;
}

/* Replace the reader's table list before it opens any of the old tables. */
struct compact_after_read {
	struct reftable_stack *writer;
	unsigned int calls;
};

static void compact_after_read(void *payload)
{
	struct compact_after_read *arg = payload;
	int err;

	if (arg->calls++)
		return;
	err = reftable_stack_compact_all(arg->writer, NULL, NULL);
	if (err)
		die("compaction failed: %d", err);
}

static int write_characterization_ref(struct reftable_writer *writer, void *payload)
{
	struct reftable_ref_record *ref = payload;
	int err;

	err = reftable_writer_set_limits(writer, ref->update_index, ref->update_index);
	if (err)
		return err;
	return reftable_writer_add_ref(writer, ref);
}

static int characterize_reload_after_compaction(const char *dir)
{
	struct reftable_stack *reader = NULL, *writer = NULL;
	struct reftable_write_options opts = { .disable_auto_compact = 1 };
	char head[] = "HEAD", branch[] = "refs/heads/main";
	struct reftable_ref_record ref = {
		.refname = head,
		.update_index = 1,
		.value_type = REFTABLE_REF_SYMREF,
		.value.symref = branch,
	}, found = { 0 };
	struct compact_after_read compact = { 0 };
	struct strbuf table_path = STRBUF_INIT;
	int fd, err;

	if (reftable_new_stack(&reader, dir, NULL) ||
	    reftable_new_stack(&writer, dir, NULL))
		die("cannot initialize reftable stacks");
	if (reftable_stack_add(writer, write_characterization_ref, &ref, &opts))
		die("cannot write HEAD");
	ref.refname = branch;
	ref.update_index = 2;
	ref.value_type = REFTABLE_REF_VAL1;
	memset(ref.value.val1, 1, REFTABLE_HASH_SIZE_SHA1);
	if (reftable_stack_add(writer, write_characterization_ref, &ref, &opts))
		die("cannot write refs/heads/main");
	if (writer->tables_len != 2)
		die("expected two uncompacted tables");

	strbuf_addf(&table_path, "%s/%s", dir, reftable_table_name(writer->tables[0]));
	fd = open(table_path.buf, O_RDONLY);
	if (fd < 0)
		die_errno("cannot hold old table open");
	compact.writer = writer;
	reader->test_after_read_list = compact_after_read;
	reader->test_after_read_list_payload = &compact;
	err = reftable_stack_reload(reader);
	printf("reload after compaction: %d\n", err);
	printf("reload attempts: %u\n", compact.calls);
	if (!err) {
		err = reftable_stack_read_ref(reader, "HEAD", &found);
		printf("read HEAD: %d\n", err);
		if (!err && found.value_type == REFTABLE_REF_SYMREF)
			printf("HEAD: %s\n", found.value.symref);
	}
	close(fd);
	strbuf_release(&table_path);
	reftable_ref_record_release(&found);
	reftable_stack_destroy(reader);
	reftable_stack_destroy(writer);
	return 0;
}

int cmd__dump_reftable(int argc, const char **argv)
{
	int err = 0;
	int opt_dump_blocks = 0;
	int opt_dump_table = 0;
	int opt_dump_stack = 0;
	uint32_t opt_hash_id = REFTABLE_HASH_SHA1;
	const char *arg = NULL, *argv0 = argv[0];

	if (argc == 3 && !strcmp(argv[1], "--delete-open"))
		return characterize_deleted_file(argv[2]);
	if (argc == 3 && !strcmp(argv[1], "--reload-after-compaction"))
		return characterize_reload_after_compaction(argv[2]);

	for (; argc > 1; argv++, argc--)
		if (*argv[1] != '-')
			break;
		else if (!strcmp("-b", argv[1]))
			opt_dump_blocks = 1;
		else if (!strcmp("-t", argv[1]))
			opt_dump_table = 1;
		else if (!strcmp("-6", argv[1]))
			opt_hash_id = REFTABLE_HASH_SHA256;
		else if (!strcmp("-s", argv[1]))
			opt_dump_stack = 1;
		else if (!strcmp("-?", argv[1]) || !strcmp("-h", argv[1])) {
			print_help();
			return 2;
		}

	if (argc != 2) {
		fprintf(stderr, "need argument\n");
		print_help();
		return 2;
	}

	arg = argv[1];

	if (opt_dump_blocks) {
		err = dump_blocks(arg);
	} else if (opt_dump_table) {
		err = dump_reftable(arg);
	} else if (opt_dump_stack) {
		err = dump_stack(arg, opt_hash_id);
	}

	if (err < 0) {
		fprintf(stderr, "%s: %s: %s\n", argv0, arg,
			reftable_error_str(err));
		return 1;
	}
	return 0;
}
