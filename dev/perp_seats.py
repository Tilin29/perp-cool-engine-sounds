"""
Copies PERP's passenger seats and exit points into lua/audio_engine/sh_carlist.lua (AudioEngine.PERP_SEATS).

  python -I perp_seats.py <garrysmod/cache/lua> ../lua/audio_engine/sh_carlist.lua

The PERP gamemode's vehicle definitions (VEHICLE.PassengerSeats / ExitPoints, shared files) reach every
client that joins the server and sit in its Lua cache: <hash>.lua, a 32-byte hash then LZMA ("alone").
Each file is replayed statement by statement (VEHICLE = {} / table.shallow_copy(BASE) / VEHICLE.Key = ...
/ GM:RegisterVehicle(VEHICLE)), so job variants built from a copy of their civilian car get its fields.
A definition found in several cached versions is taken from the newest cache file. Each car of
AudioEngine.CAR_MODELS gets the definition whose PaintJobs use its model, the one on the car's own
script first. The table is written between the BEGIN / END PERP_SEATS lines.
"""
import lzma, os, re, sys

NUMBER = r'(-?\d+(?:\.\d+)?)'
VECTOR = re.compile(r'Vector\(\s*' + NUMBER + r'\s*,\s*' + NUMBER + r'\s*,\s*' + NUMBER + r'\s*\)')
ANGLE = re.compile(r'Angle\(\s*' + NUMBER + r'\s*,\s*' + NUMBER + r'\s*,\s*' + NUMBER + r'\s*\)')
STATEMENT = re.compile(r'^(?:local\s+)?(\w+)(?:\.(\w+))?\s*=\s*', re.M)
REGISTER = re.compile(r'RegisterVehicle\(\s*(\w+)\s*\)')
BEGIN, END = '-- BEGIN PERP_SEATS', '-- END PERP_SEATS'


def unpack(path):
    data = open(path, 'rb').read()
    try:
        return lzma.decompress(data[32:], format=lzma.FORMAT_ALONE).rstrip(b'\0').decode('utf-8', 'replace')
    except lzma.LZMAError:
        return ''


def value_at(text, start):
    """the value from start to the end of its balanced braces / parentheses, else to the end of the line"""
    depth, index, in_string = 0, start, False
    while index < len(text):
        character = text[index]
        if in_string:
            if character == '"' and text[index - 1] != '\\':
                in_string = False
        elif character == '"':
            in_string = True
        elif character in '{(':
            depth += 1
        elif character in '})':
            depth -= 1
        elif character == '\n' and depth <= 0:
            break
        index += 1
    return text[start:index].strip()


def string_field(fields, key):
    match = re.match(r'"([^"]*)"', fields.get(key) or '')
    return match.group(1) if match else None


def definition(fields, modified):
    seats = []
    for line in (fields.get('PassengerSeats') or '').splitlines():
        position, angles = VECTOR.search(line), ANGLE.search(line)
        if position:
            seats.append([float(value) for value in position.groups()] + ([float(value) for value in angles.groups()] if angles else [0.0, 0.0, 0.0]))
    return {
        'id': string_field(fields, 'ID'),
        'name': string_field(fields, 'Name'),
        'script': (string_field(fields, 'Script') or '').lower(),
        'models': {model.lower() for model in re.findall(r'model\s*=\s*"([^"]+)"', fields.get('PaintJobs') or '')},
        'hasSeats': 'PassengerSeats' in fields,
        'seats': seats,
        'exits': [[float(value) for value in match.groups()] for match in VECTOR.finditer(fields.get('ExitPoints') or '')],
        'modified': modified,
    }


def read_definitions(cache_folder):
    definitions = {}
    for file_name in os.listdir(cache_folder):
        path = os.path.join(cache_folder, file_name)
        text = unpack(path)
        if 'RegisterVehicle' not in text:
            continue
        modified = os.path.getmtime(path)
        tables = {}
        events = [(match.start(), 'assign', match) for match in STATEMENT.finditer(text)]
        events += [(match.start(), 'register', match) for match in REGISTER.finditer(text)]
        for _, kind, match in sorted(events, key=lambda event: event[0]):
            if kind == 'register':
                fields = tables.get(match.group(1))
                if fields and 'ID' in fields:
                    entry = definition(fields, modified)
                    known = definitions.get(entry['id'])
                    if entry['id'] and (not known or modified > known['modified']):
                        definitions[entry['id']] = entry
                continue
            target, key = match.group(1), match.group(2)
            value = value_at(text, match.end())
            if key:
                if target in tables:
                    tables[target][key] = value
            elif value.startswith('{}'):
                tables[target] = {}
            else:
                copied = re.match(r'table\.(?:shallow_copy|Copy)\(\s*(\w+)\s*\)', value)
                if copied:
                    tables[target] = dict(tables.get(copied.group(1), {}))
    return definitions


def number(value):
    text = ('%.1f' % value).rstrip('0').rstrip('.')
    return '0' if text in ('-0', '') else text


def main(cache_folder, carlist_path):
    carlist = open(carlist_path, encoding='utf-8').read()
    cars = {match.group(1): (match.group(2).lower(), match.group(3).lower())
            for match in re.finditer(r'^\s*\["([^"]+)"\]\s*=\s*\{\s*"([^"]+\.mdl)",\s*"([^"]+)"', carlist, re.M)}
    definitions = read_definitions(cache_folder)
    lines, missing = ['AudioEngine.PERP_SEATS = {'], []
    for car, (model, script) in sorted(cars.items()):
        script_name = os.path.splitext(os.path.basename(script))[0]
        candidates = [entry for entry in definitions.values() if model in entry['models'] and entry['hasSeats']]
        if not candidates:
            missing.append(car)
            continue
        candidates.sort(key=lambda entry: (entry['script'] != script_name, -entry['modified']))
        chosen = candidates[0]
        seats = ', '.join('{ ' + ', '.join(number(value) for value in seat) + ' }' for seat in chosen['seats'])
        exits = ', '.join('{ ' + ', '.join(number(value) for value in point) + ' }' for point in chosen['exits'])
        comment = '' if chosen['name'] == car else '   -- PERP: ' + chosen['name']
        lines.append('\t["%s"] = {%s' % (car, comment))
        lines.append('\t\tseats = { %s },' % seats if seats else '\t\tseats = {},')
        lines.append('\t\texits = { %s },' % exits if exits else '\t\texits = {},')
        lines.append('\t},')
    lines.append('}')
    start, end = carlist.index(BEGIN), carlist.index(END)
    start = carlist.index('\n', start) + 1
    carlist = carlist[:start] + '\n'.join(lines) + '\n' + carlist[end:]
    open(carlist_path, 'w', encoding='utf-8', newline='').write(carlist)
    print('%d PERP definitions, %d of %d cars with PERP seats; without (estimates kept): %s'
          % (len(definitions), len(cars) - len(missing), len(cars), ', '.join(missing) or '-'))


if __name__ == '__main__':
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
