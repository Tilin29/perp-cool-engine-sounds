"""
Builds the PERP car -> model / vehicle script table for lua/audio_engine/sh_carlist.lua.

  python -I perp_carmodels.py <extracted dev pack> <file index> > out.lua

<extracted dev pack>  folder holding scripts/vehicles/ from the PERP dev content (workshop 3792392486)
<file index>          text file with one game path per line, of every mounted content pack (to check models exist)

Wheel radius comes from each car's base script (first "Radius", Source units are inches).
The MAP below was matched by hand from model, script and material names in the content packs.
"""
import os, re, sys

MAP = """
Alfa Romeo 33 Stradale (1967)|alfa_stradale|tdmcars/alfa_stradale
Alfa Romeo Giulietta|alfa_giulietta|tdmcars/alfa_giulietta
Aston Martin DB5|ast_db5|tdmcars/ast_db5
Aston Martin DBS|dbs|tdmcars/dbs
Aston Martin Rapide|ast_rapide|tdmcars/ast_rapide
Aston Martin V12 Vantage|aston_v12vantage|tdmcars/v12vantage
Audi R8 Plus|audi_r8_plus|tdmcars/audir8plus
Audi R8 Spyder|audi_r8_spyder|tdmcars/audir8spyd
Audi R8 V10|audir8|tdmcars/audir8
Audi RS4 Avant|aud_rs4avant|tdmcars/rs4avant
Audi S5|s5|tdmcars/s5
Audi TT 2007|auditt|tdmcars/auditt
BMW 1M|bmw_1m|tdmcars/bmw_1m
BMW 340i|bmw_340i|tdmcars/bmw_340i
BMW 507|bmw507|tdmcars/507
BMW M1|bmwm1|tdmcars/m1
BMW M3 E92|bmwm3e92|tdmcars/bmwm3e92
BMW M5 E34|bmwm5e34|tdmcars/bmwm5e34
BMW M5 E60|bmwm5e60|tdmcars/bmwm5e60
BMW M6 2013|bmw_m6_13|tdmcars/bmwm613
Bowler EXR-S|bowler_exrs|tdmcars/bowlerexrs
Bugatti EB110|bug_eb110|tdmcars/eb110
Bugatti Veyron 16.4|bug_veyron|tdmcars/veyron
Bugatti Veyron SS|bug_veyronss|tdmcars/veyronss
Cadillac Escalade 2012|cad_escalade|tdmcars/escalade
Chevrolet Blazer|chev_blazer|tdmcars/blazer
Chevrolet C10|chev_c10|tdmcars/che_c10
Chevrolet Camaro SS 69|69camaro|tdmcars/69camaro
Chevrolet Camaro ZL1|chev_camzl1|tdmcars/camarozl1
Chevrolet Chevelle SS|chevelless|tdmcars/chevelless
Chevrolet Corvette GSC|chev_corv_gsc|tdmcars/chev_corv_gsc
Chevrolet Corvette Stingray 427|chev_stingray427|tdmcars/chevstingray427
Chevrolet Impala SS 96|chev_impala96|tdmcars/impala96
Chevrolet Spark|spark|tdmcars/spark
Chrysler 300C|chr_300c|tdmcars/300c
Chrysler PT Cruiser|chr_ptcruiser|tdmcars/ptcruiser
Citroen C1|citroen_c1|tdmcars/citroenc1
Citroen C4|cit_c4|tdmcars/c4
DeLorean DMC-12|del_dmc|tdmcars/delorean
Dodge Challenger 1970|dod_challenger70|tdmcars/challenger70
Dodge Challenger 2015|dod_challenger15|tdmcars/dod_challenger15
Dodge Charger 2012|dod_charger12|tdmcars/charger2012
Dodge Charger SRT-8|chargersrt8|tdmcars/chargersrt8
Dodge RAM SRT10|dodgeram|tdmcars/dodgeram
Dodge Viper GTS|vip_viper|tdmcars/vipviper
Dundreary Limousine|@models/sickness/stretchdr_tdmcars.mdl|perp2/stretch
Ferrari 250 GTO|fer_250gto|tdmcars/fer_250gto
Ferrari 250GT|ferrari250gt|tdmcars/ferrari250gt
Ferrari 458 Spider|fer_458spid|tdmcars/fer458spid
Ferrari 512 TR|ferrari512tr|tdmcars/ferrari512tr
Ferrari Enzo|fer_enzo|tdmcars/enzo
Ferrari F12 Berlinetta|fer_f12|tdmcars/fer_f12
Ferrari F430|fer_f430|tdmcars/fer_f430
Ferrari F50|fer_f50|tdmcars/f50
Ferrari LaFerrari|fer_lafer|tdmcars/laferrari
Ford Crown Victoria|crownvic_taxi|tdmcars/crownvic
Ford Deluxe Coupe 1940|ford_coupe_40|tdmcars/coupe40
Ford F100|for_f100|tdmcars/f100
Ford F350|for_f350|tdmcars/f350
Ford Focus RS|focusrs|tdmcars/focusrs
Ford Focus SVT|for_focussvt|tdmcars/focussvt
Ford GT 05|gt05|tdmcars/gt05
Ford Mustang GT|for_mustanggt|tdmcars/mustanggt
Ford Raptor SVT|for_raptor|tdmcars/raptorsvt
Ford Shelby GT500|gt500|tdmcars/gt500
Ford Transit|ford_transit|tdmcars/transit
GMC Sierra|gmc_sierralow|tdmcars/sierralow
GMC Syclone|gmc_syclone|tdmcars/syclone
GMC Vandura|gmcvan|tdmcars/gmcvan
Holden HSV GTS|hsvgts|tdmcars/hsvgts
Holden HSV W427|hsvw427|tdmcars/hsvw427
Honda CR-X SiR|hon_crxsir|tdmcars/hon_crxsir
Honda Civic Type R|civic_typer|tdmcars/civictyper
Honda Civic Type R 1997|hon_civic97|tdmcars/civic97
Honda S2000|hon_s2000|tdmcars/s2000
Hudson Hornet|hud_hornet|tdmcars/hudhornet
Hummer H1|hummerh1|tdmcars/h1
Jaguar E-Type|jag_etype|tdmcars/jag_etype
Jaguar F-Type|jag_ftype|tdmcars/jag_ftype
Jeep Grand Cherokee|jeep_grandche|tdmcars/grandche
Jeep Wrangler|wrangler|tdmcars/wrangler
Kia Ceed|kia_ceed|tdmcars/ceed
Kia Forte Koup|kia_fortekoup|tdmcars/kiafortekoup
Lamborghini Diablo|lambo_diablo|tdmcars/diablo
Lamborghini Gallardo|gallardo|tdmcars/gallardo
Lamborghini Gallardo LP570-4 Spyder Performante|lam_gallardospyd|tdmcars/gallardospyd
Lamborghini Miura|lambo_miuracon|tdmcars/miuracon
Lamborghini Murcielago|murcielago|tdmcars/murcielago
Lamborghini Murcielago LP670-4 SV|lambo_murcielagosv|tdmcars/murcielagosv
Lamborghini Reventon Roadster|reventon_roadster|tdmcars/reventonr
Land Rover Defender|landrover_defender|tdmcars/lrdefender
Land Rover Range Rover 08|landrover|tdmcars/landrover
Land Rover Range Rover 2012|landrover12|tdmcars/landrover12
Lexus IS 300|lex_is300|tdmcars/lex_is300
Lexus IS F|lex_isf|tdmcars/lex_isf
Maserati Ghibli S|mas_ghibli|tdmcars/mas_ghibli
Maserati Quattroporte Sport GT S|mas_quattroporte|tdmcars/mas_quattroporte
Mazda Furai|maz_furai|tdmcars/furai
Mazda MX-5 2007|mx5|tdmcars/mx5
Mazda RX-8|rx8|tdmcars/rx8
Mazda RX7|maz_rx7|tdmcars/rx7
Mazda Speed 3 2009|maz_speed3|tdmcars/speed3
McLaren F1|mclaren_f1|tdmcars/mclarenf1
McLaren P1|mclaren_p1|tdmcars/mclarenp1
Mercedes 300 SEL|mer_300sel|tdmcars/mer300sel
Mercedes 300SL Gullwing Coupe|mer_300slgull|tdmcars/mer300slgull
Mercedes C32 AMG|mercedes_c32|tdmcars/c32
Mercedes E63 AMG|mer_e63|tdmcars/mere63
Mercedes G-Class|gwagon|jarheads/gwagon
Mercedes ML63 AMG|mer_ml63|tdmcars/ml63
Mercedes McLaren SLR|mer_slr|tdmcars/mer_slr
Mercedes SL65 AMG|sl65amg|tdmcars/sl65amg
Mercedes SLS AMG|mer_slsamg|tdmcars/slsamg
Mini Clubman|mini_clubman|tdmcars/miniclubman
Mini Cooper 1965|cooper65|tdmcars/cooper65
Mini Cooper S 2011|mini_coopers11|tdmcars/minicoopers11
Mini Coupe|mini_coupe|tdmcars/minicoupe
Mitsubishi Colt Ralliart|coltralliart|tdmcars/colt
Mitsubishi Eclipse GSX|mit_eclipsegsx|tdmcars/mit_eclipsegsx
Mitsubishi Eclipse GT|mitsu_eclipgt|tdmcars/mitsu_eclipgt
Mitsubishi Lancer Evo VIII|mitsu_evo8|tdmcars/mitsu_evo8
Mitsubishi Lancer Evo X|mitsu_evox|tdmcars/mitsu_evox
Morgan Aero SS|morg_aeross|tdmcars/morg_aeross
Nissan 350z|350z|tdmcars/350z
Nissan 370Z|nis_370z|tdmcars/370z
Nissan GT-R SpecV|nissan_gtr|tdmcars/gtr
Nissan Leaf|nis_leaf|tdmcars/nis_leaf
Nissan Silvia|nissan_silvias15|tdmcars/nissilvs15
Nissan Skyline R34|skyline_r34|tdmcars/skyline_r34
Noble M600|noblem600|tdmcars/noblem600
Pagani Zonda C12|zondac12|tdmcars/c12
Pontiac Fiero GT|pon_fierogt|tdmcars/pon_fierogt
Pontiac Firebird Trans Am|pon_firetransam|tdmcars/pon_firetransam
Porsche 911 GT3|gt3rs|jarheads/gt3rs
Porsche 918 Spyder|por_918|tdmcars/918spyd
Porsche 997 GT3|997gt3|tdmcars/997gt3
Porsche Carrera GT|por_carreragt|tdmcars/carreragt
Porsche Cayenne Turbo 2012|por_cayenne12|tdmcars/cayenne12
Porsche Cayenne Turbo S|cayenne|tdmcars/cayenne
Scion FR-S|scion_frs|tdmcars/scionfrs
Scion tC|scion_tc|tdmcars/sciontc
Scion xD|scion_xd|tdmcars/scionxd
Shelby 1000|she_1000|tdmcars/she1000
Subaru Impreza WRX STI|sub_wrxsti08|tdmcars/subimpreza08
Subaru Legacy GT 2010|sub_legacygt10|tdmcars/subleggt10
Subaru Legacy RS 1990|sub_legacyrs90|tdmcars/sublegrs90
Tesla Model S|tesla_models|tdmcars/teslamodels
Toyota FJ Cruiser|toy_fj|tdmcars/toyfj
Toyota MR2 GT|toy_mr2gt|tdmcars/mr2gt
Toyota Prius|prius|tdmcars/prius
Toyota Supra|supra|tdmcars/supra
Vauxhall Agila|vaux_agila|tdmcars/vaux_agila
Vauxhall Astra|vaux_astra12|tdmcars/vauxastra12
Vauxhall Corsa|vaux_corsa|tdmcars/vaux_corsa
Vauxhall Insignia|vaux_insignia|tdmcars/vaux_insignia
Volkswagen Beetle 1967|beetle|tdmcars/beetle67
Volkswagen Camper 1965|vw_camper65|tdmcars/vwcamper
Volkswagen Golf GTI 2014|vw_golfgti_14|tdmcars/vw_golfgti_14
Volkswagen Golf MKII|golf_mk2|tdmcars/golfmk2
Volkswagen Golf MKIII|golf3|tdmcars/golf3
Volkswagen New Beetle|vw_beetleconv|tdmcars/vwbeetleconv
Volkswagen Scirocco GT|scirocco|tdmcars/scirocco
Volvo 242 Turbo|242turbo|tdmcars/242turbo
Volvo 850R|vol_850r|tdmcars/850r
Volvo S60|vol_s60|tdmcars/vols60
"""

def main():
    pack, index = sys.argv[1], sys.argv[2]
    V = os.path.join(pack, "scripts", "vehicles")
    paths = set(l.strip().lower() for l in open(index, encoding="utf-8"))
    rows = [l.split("|") for l in MAP.strip().splitlines()]
    print("%d cars" % len(rows), file=sys.stderr)
    seen, bad = {}, 0
    for name, m, s in rows:
        mdl = m[1:] if m.startswith("@") else "models/tdmcars/%s.mdl" % m
        if mdl not in paths:
            print("MISSING MODEL", name, mdl, file=sys.stderr); bad += 1
        if mdl in seen:
            print("DUPLICATE MODEL", name, seen[mdl], file=sys.stderr); bad += 1
        seen[mdl] = name
        pk, base = s.split("/")
        sp = os.path.join(V, pk, base + ".txt")
        radius = None
        if not os.path.exists(sp):
            print("MISSING SCRIPT", name, s, file=sys.stderr); bad += 1
        else:
            mm = re.search(r'"radius"\s+"([\d.]+)"', open(sp, encoding="latin-1").read(), re.I)
            radius = float(mm.group(1)) if mm else None
        tiers = [d for d in ("used", "upgrade_1", "upgrade_2", "spiked") if os.path.exists(os.path.join(V, pk, d, base + ".txt"))]
        wr = "%.3f" % (radius * 0.0254) if radius else "nil"
        print('\t["%s"] = { "%s", "scripts/vehicles/%s.txt", %s }, -- %s' % (name, mdl, s, wr, " ".join(tiers) or "no tiers"))
    sys.exit(1 if bad else 0)

main()
