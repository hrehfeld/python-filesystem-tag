#!/usr/bin/env python3

from pathlib import Path
import argparse

import hashlib
import json

import sys

import prompt

__VERSION__ = '0.0.1'

tag_base_dir = Path('~/tags').expanduser()


AND_TOKEN = '+'
NOT_TOKEN = '!'


def unique_list(l):
    r = []
    for e in l:
        if e not in r:
            r.append(e)
    return r


def tag_dir(tag):
    return tag_base_dir / tag


def get_search_dir(tags):
    tags = [tag if AND else NOT_TOKEN + tag for tag, AND in tags.items()]
    return tag_base_dir / AND_TOKEN.join(tags)
    

def sha256_file(filename):
    h = hashlib.sha256()
    b = bytearray(128*1024)
    mv = memoryview(b)
    with open(filename, 'rb', buffering=0) as f:
        for n in iter(lambda: f.readinto(mv), 0):
            h.update(mv[:n])
    return h.hexdigest()


def file_name(p):
    p = p.absolute()
    #name_hash = hashlib.sha256(str(p).encode()).hexdigest()
    file_hash = sha256_file(str(p))
    name = '-'.join(list(p.parts[1:-1]) + [p.stem, file_hash]) + p.suffix
    return name


def with_tag(tag, *paths):
    dir = tag_dir(tag)
    r = set()
    if not dir.exists():
        return r

    for path in paths:
        for tagged in dir.iterdir():
            if tagged.resolve() == path:
                r.add(tag_dir.name)
    return r


def get_tag_files(tag):
    dir = tag_dir(tag)
    if not dir.exists():
        return set()
    return set([p.resolve() for p in dir.iterdir()])


def get_file_tags(*paths):
    tags = dict()
    for path in paths:
        tags[path] = set()

    for tag_dir in tag_base_dir.iterdir():
        assert tag_dir.is_dir(), tag_dir
        # TODO might be expensive
        for tagged in tag_dir.iterdir():
            for path in paths:
                if tagged.resolve() == path:
                    tags[path].add(tag_dir.name)
    return tags
    

def add_link(dir, path, name):
    dst = dir / name
    if not dst.exists():
        dst.parent.mkdir(exist_ok=True, parents=True)
        dst.symlink_to(path, path.is_dir())
    

def remove_link(dir, path, name):
    dst = dir / name
    if dst.exists():
        dst.unlink()
    else:
        print("WARNING: '{p}' is not tagged as '{t}'".format(p=path, t=dir.name))


def unserialize_tag(s):
    AND = True
    if s.startswith(NOT_TOKEN):
        s = s[len(NOT_TOKEN):]
        AND = False
    return s, AND


def unserialize_tags(s):
    search = s.split(AND_TOKEN)
    assert search
    search = dict([unserialize_tag(s) for s in search])
    return search


def check_tags_prompt(tags):
    if not tags:
        tags = prompt.prompt('Tags (%s separated, %s for NOT):' % (AND_TOKEN, NOT_TOKEN))
        return unserialize_tags(tags)
    return dict([unserialize_tag(tag) for tag in tags])


def merge_file_tags(changed_tags, file_tags):
    for tag, AND in changed_tags.items():
        if AND:
            file_tags.add(tag)
        elif tag in file_tags:
            file_tags.remove(tag)


def merge_searches(changed_tags, searches):
    for tag, AND in changed_tags.items():
        e = {tag: True}
        if e not in searches:
            searches.append(e)


def get_existing():
    r = []
    if tag_base_dir.exists():
        for p in (p for p in tag_base_dir.iterdir() if p.is_dir()):
            search = unserialize_tags(p.name)
            r.append(search)
    return r


def update_searches(searches, file, file_name, file_tags, check_tags):
    for search_tags in searches:
        member = True
        check = False
        for search_tag, AND in search_tags.items():
            has_tag = search_tag in file_tags
            check = check or search_tag in check_tags
            if AND and not has_tag:
                member = False
                break
            if not AND and has_tag:
                member = False
                break

        if check:
            search_dir = get_search_dir(search_tags)
            if member:
                add_link(search_dir, file, file_name)
            else:
                remove_link(search_dir, file, file_name)


TYPE_ADD = 0
TYPE_REMOVE = 1
TYPE_SEARCH = 2

def main():
    arg_parser = argparse.ArgumentParser()
    arg_parser.add_argument('--version', action='store_true')

    subp = arg_parser.add_subparsers()

    add = subp.add_parser('add')
    add.set_defaults(type=TYPE_ADD)

    rem = subp.add_parser('rem')
    rem.set_defaults(type=TYPE_REMOVE)

    search = subp.add_parser('search')
    search.set_defaults(type=TYPE_SEARCH)

    with_tags_parsers = add, rem, search
    for parser in with_tags_parsers:
        parser.add_argument('-t', '--tags', dest='tags', nargs='+')

    with_files_parsers = add, rem
    for parser in with_files_parsers:
        parser.add_argument('files', nargs='+', type=Path)
        
    args = arg_parser.parse_args()

    if args.version:
        print(__VERSION__)
        exit(0)
        
    if not hasattr(args, 'type'):
        arg_parser.print_usage()
        exit(1)
    del arg_parser

    if args.type in (TYPE_ADD, TYPE_REMOVE):
        for p in args.files:
            if not p.exists():
                raise FileNotFoundError(p)

        tags = check_tags_prompt(args.tags)

        # remove just makes everything negated
        if args.type == TYPE_REMOVE:
            for tag in tags:
                if not tags[tag]:
                    # TODO invalid argument exception
                    raise Exception('removing negated tags is undefined behavior -- what do you actually wanna do?')
                tags[tag] = False

        tag_base_dir.mkdir(exist_ok=True, parents=True)

        files = [p.absolute() for p in args.files]

        existing_tags = get_file_tags(*files)

        searches = get_existing()
        merge_searches(tags, searches)

        for p in files:
            file_tags = existing_tags[p]
            merge_file_tags(tags, file_tags)
            
            name = file_name(p)
            update_searches(searches, p, name, file_tags, tags)
                
    elif args.type == TYPE_SEARCH:
        tags = check_tags_prompt(args.tags)

        and_tags = [t for t, AND in tags.items() if AND]
        not_tags = [t for t, AND in tags.items() if not AND]

        if not and_tags:
            raise Exception('Searches need at least one AND tag')

        candidates = get_tag_files(and_tags[0])
        for tag in and_tags[1:]:
            candidates = set([p for p in get_tag_files(tag) if p in candidates])
            
        for tag in not_tags:
            candidates = with_tag(tag, candidates)
            
        search_dir = get_search_dir(tags)
        search_dir.mkdir(exist_ok=True, parents=True)

        for p in candidates:
            name = file_name(p)
            add_link(search_dir, p, name)


if __name__ == '__main__':
    main()
