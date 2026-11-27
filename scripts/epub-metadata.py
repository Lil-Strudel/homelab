#!/usr/bin/env python3
"""Write a book's title, authors, series, year, language and description into an epub.

    epub-metadata.py BOOK.epub '{"title": ..., "authors": [...], "series": ..., "position": ...,
                                 "year": ..., "description": ..., "language": ...}'

The file is replaced only if the rewritten package parses. Prints the metadata it ends up with.
Uses only the standard library, so it runs inside the Shelfmark pod:

    kubectl -n media exec -i deploy/shelfmark -- python3 - BOOK.epub "$META" < epub-metadata.py
"""
import json
import os
import re
import sys
import tempfile
import xml.etree.ElementTree as ET
import zipfile
from html import escape, unescape


def opf_path(z):
    container = z.read('META-INF/container.xml').decode('utf-8', 'replace')
    return re.search(r'full-path="([^"]+)"', container).group(1)


def words(name):
    return re.sub(r'[^a-z0-9]+', ' ', name.lower()).split()


def tags(body, name):
    return list(re.finditer(rf'<{name}\b[^>]*?(?:/>|>.*?</{name}>)', body, re.S))


def text(tag):
    return unescape(re.sub(r'<[^>]+>', '', tag).strip())


def drop(body, matches):
    for m in reversed(matches):
        body = body[:m.start()] + body[m.end():]
    return body


def drop_refines(body, ids):
    for i in ids:
        body = re.sub(rf'\s*<meta\b[^>]*refines="#{re.escape(i)}"[^>]*>[^<]*</meta>', '', body)
    return body


def keep_named_authors(wanted, present):
    # The book database lists audiobook narrators as authors, so trust only the names the
    # file also carries, spelled the database's way.
    surnames = {w for name in present for w in words(name)}
    named = [a for a in wanted if words(a) and words(a)[-1] in surnames]
    return named or wanted[:1]


def set_authors(body, wanted):
    creators = tags(body, 'dc:creator')
    authors = keep_named_authors(wanted, [text(c.group(0)) for c in creators])
    ids = [i for c in creators for i in re.findall(r'\bid="([^"]+)"', c.group(0))]
    body = drop_refines(body, ids)
    body = drop(body, [t for t in tags(body, 'meta') if 'name="calibre:author_link_map"' in t.group(0)])
    creators = tags(body, 'dc:creator')
    new = '\n    '.join(f'<dc:creator>{escape(a, False)}</dc:creator>' for a in authors)
    if not creators:
        return body + f'  {new}\n  '
    body = drop(body, creators[1:])
    first = creators[0]
    return body[:first.start()] + new + body[first.end():]


def set_series(body, series, position):
    body = drop(body, [m for m in tags(body, 'meta') if re.search(r'name="calibre:series(?:_index)?"', m.group(0))])
    collections = [m for m in tags(body, 'meta') if 'property="belongs-to-collection"' in m.group(0)]
    body = drop_refines(body, [i for m in collections for i in re.findall(r'\bid="([^"]+)"', m.group(0))])
    body = drop(body, [m for m in tags(body, 'meta') if 'property="belongs-to-collection"' in m.group(0)])
    # Kavita groups a book into a series only when both the name and the index are present.
    if not series or position is None:
        return body
    index = float(position)
    index = str(int(index)) if index == int(index) else str(index)
    return body + (f'  <meta name="calibre:series" content="{escape(series)}"/>\n'
                   f'    <meta name="calibre:series_index" content="{index}"/>\n  ')


def set_year(body, year):
    body = re.sub(r'<dc:date\b([^>]*)/>', r'<dc:date\1></dc:date>', body)
    if not re.search(r'<dc:date\b', body):
        return body + f'  <dc:date>{year}</dc:date>\n  '
    return re.sub(r'(<dc:date\b[^>]*>).*?(</dc:date>)', lambda m: m.group(1) + year + m.group(2), body, flags=re.S)


def set_language(body, language):
    if not re.search(r'<dc:language\b', body):
        return body + f'  <dc:language>{language}</dc:language>\n  '
    return re.sub(r'(<dc:language\b[^>]*>)[^<]*(</dc:language>)', rf'\g<1>{language}\2', body)


def add_description(body, description):
    body = re.sub(r'\s*<dc:description\b[^>]*/>', '', body)
    body = re.sub(r'\s*<dc:description\b[^>]*>\s*</dc:description>', '', body)
    if re.search(r'<dc:description\b[^>]*>\s*[^<\s]', body):
        return body
    return body + f'  <dc:description>{escape(description, False)}</dc:description>\n  '


def fix_cover(opf, body):
    # Kavita refuses to read an epub whose cover meta names no manifest item.
    cover = next((m for m in tags(body, 'meta') if re.search(r'name="cover"', m.group(0))), None)
    if not cover:
        return body
    target = re.search(r'content="([^"]*)"', cover.group(0))
    ids = re.findall(r'<item\b[^>]*\bid="([^"]+)"', opf)
    if target and target.group(1) in ids:
        return body
    image = re.search(r'<item\b(?=[^>]*properties="[^"]*cover-image)[^>]*\bid="([^"]+)"', opf) or \
        re.search(r'<item\b(?=[^>]*media-type="image/)(?=[^>]*cover)[^>]*\bid="([^"]+)"', opf)
    if not image:
        return drop(body, [cover])
    fixed = f'<meta name="cover" content="{image.group(1)}"/>'
    return body[:cover.start()] + fixed + body[cover.end():]


def fix(opf, meta):
    m = re.search(r'(<(?:\w+:)?metadata\b[^>]*>)(.*?)(</(?:\w+:)?metadata>)', opf, re.S)
    body = m.group(2)
    if meta.get('title'):
        body = re.sub(r'(<dc:title\b[^>]*>).*?(</dc:title>)',
                      lambda t: t.group(1) + escape(meta['title'], False) + t.group(2), body, count=1, flags=re.S)
        body = drop(body, [t for t in tags(body, 'meta') if 'name="calibre:title_sort"' in t.group(0)])
    if meta.get('authors'):
        body = set_authors(body, meta['authors'])
    body = set_series(body, meta.get('series'), meta.get('position'))
    if meta.get('year'):
        body = set_year(body, str(meta['year']))
    if meta.get('language'):
        body = set_language(body, meta['language'])
    if meta.get('description'):
        body = add_description(body, meta['description'])
    body = fix_cover(opf, body)
    return opf[:m.start()] + m.group(1) + body + m.group(3) + opf[m.end():]


def report(opf):
    body = re.search(r'<(?:\w+:)?metadata\b.*?</(?:\w+:)?metadata>', opf, re.S).group(0)
    def meta(name):
        tag = next((t.group(0) for t in tags(body, 'meta') if f'name="{name}"' in t.group(0)), '')
        value = re.search(r'content="([^"]*)"', tag)
        return unescape(value.group(1)) if value else '-'
    print('title\t' + text(tags(body, 'dc:title')[0].group(0)))
    print('authors\t' + ', '.join(text(c.group(0)) for c in tags(body, 'dc:creator')))
    print(f'series\t{meta("calibre:series")} #{meta("calibre:series_index")}')
    print('year\t' + ', '.join(text(d.group(0)) for d in tags(body, 'dc:date')))
    print('language\t' + ', '.join(text(d.group(0)) for d in tags(body, 'dc:language')))
    print('description\t' + ('yes' if re.search(r'<dc:description\b[^>]*>\s*[^<\s]', body) else 'no'))


def main(path, meta_json):
    meta = json.loads(meta_json)
    with zipfile.ZipFile(path) as zin:
        name = opf_path(zin)
        opf = fix(zin.read(name).decode('utf-8'), meta)
        ET.fromstring(opf.encode('utf-8'))
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), suffix='.epub')
        os.close(fd)
        try:
            with zipfile.ZipFile(tmp, 'w') as zout:
                mimetype = zin.read('mimetype') if 'mimetype' in zin.namelist() else b'application/epub+zip'
                zout.writestr(zipfile.ZipInfo('mimetype'), mimetype, compress_type=zipfile.ZIP_STORED)
                for item in zin.infolist():
                    if item.filename == 'mimetype':
                        continue
                    data = opf.encode('utf-8') if item.filename == name else zin.read(item.filename)
                    zout.writestr(item.filename, data, compress_type=zipfile.ZIP_DEFLATED)
            os.chmod(tmp, os.stat(path).st_mode & 0o777)
            os.replace(tmp, path)
        except BaseException:
            os.unlink(tmp)
            raise
    report(opf)


if __name__ == '__main__':
    main(*sys.argv[1:3])
