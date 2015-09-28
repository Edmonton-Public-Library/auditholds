
Project Notes
-------------
Initialized: Wed Sep 9 11:29:32 MDT 2015.

Instructions for Running:
```
./auditholds -x
```

Product Description:
--------------------
Perl script written by Andrew Nisbet for Edmonton Public Library, distributable by the enclosed license.
This tools audits holds, as the name suggests, and repairs where possible, but reports hold problems. Typically this tool looks for orphaned holds, holds that cannot be fufilled because Symphony doesn't handle volume holds properly. If a title has several volumes customers can place holds on any discrete volume and the hold should be filled. But we have noticed problems with this system. 

If a title has 4 volumes and only one copy of each volume, Symphony treats the title as if were just 4 copies of a title, and moves the customer holds to a single copy. If that copy is discarded, the holds will never be filled and worse no one notices until customers complain.

If a title has several items but the item's format differ, the ILS treats it as if it were separate volumes. Sometimes this is Ok, but other times it is important to get the material to the customer regardless of the material's format.

To get a report of the scope of the problem we first find all the active holds, that are not available, collect all the callnums sort and count them.

```
selhold -j"ACTIVE" -a"N" -oN | sort | uniq | selcallnum -iN -oCD
```
which produces a list of cat key and callnum:
```
...
998136|General fiction A TradePBK|
998170|332.024 PAI|
998187|152.47 KOL|
998224|DVD NIN|
998226|DVD ABO|
998244|DVD JUS|
998244|DVD JUS|
998247|DVD LIK|
998260|DVD RUM|
998263|DVD SHE|
998277|DVD CAR|
998277|DVD CAR|
998277|DVD CAR|
998278|DVD EXT|
998278|DVD EXT|
998278|DVD EXT|
998279|DVD GIR|
998279|DVD GIR|
998279|DVD GIR|
998279|DVD GIR|
998280|DVD J|
998280|DVD J|
998280|DVD J|
998280|DVD J|
998294|CD POP VOC/M SHE|
...
```
Now count all the titles with more than 2 different callnums:
```
cat cat_key_callnum_holds.lst | sort -u | pipe.pl -o'c0' -dc0 -A | pipe.pl -W'\s+' -C'c0:gt2' | pipe.pl -sc1 -U
```
Which produces a list of counts of callnums per cat key driven from the holds table.
```
4|4746
3|71389
3|360603
3|383153
3|423411
8|465387
3|489990
4|513903
5|513904
5|513945
3|513966
5|513970
4|513976
8|532704
4|589054
4|638357
3|653802
3|702706
5|816689
4|816694
3|816698
3|856219
4|883860
3|887369
4|889008
3|942661
3|942959
3|945009
4|1039254
3|1253648
3|1353655
3|1355980
3|1482733
3|1482740
5|1517802
```
A look up on each of these catalog keys can be done to check the holds are on visible callnums.
Here is an example of when things go right.
```
echo 71389 | selhold -iC -oN -jACTIVE -aN -oN | sort | selcallnum -iN -oNDz
```
Which produces the following, but importantly each different callnum is visible, meaning it has a viable item attached to it.
```
71389|573|CD SOU EFFEC GIB v.9|1|
71389|624|CD SOU EFFEC GIB v.5|1|
71389|628|CD SOU EFFEC GIB v.3|1|
```
On the other hand things can go wrong. Here is an example of when holds get stuck. In this example there are 37 holds on items in callnum range 'BEGINNING CHAPTER BOOKS - SERIES G PBK', but there are no visible copies on that callnum.
```
echo 1440094 | selhold -iC -oN -jACTIVE -aN -oN | sort | selcallnum -iN -oNDz | sort -n | uniq –c
```
Shows an example of a problem. There are 37 holds that has 0 visible callnums.
```
37 1440094|1|BEGINNING CHAPTER BOOKS - SERIES G PBK|0| 
3 1440094|18|J GER|3|
1 1440094|2|Beginning chapter books - Series G PBK|1|
```

Considerations: call numbers with no items
------------------------------------------
API to remove a call number:
```
E201509171212240004R ^S96FVFFADMIN^FEEPLMNA^FcNONE^FWADMIN^IQJ 220.95 MACK(1235545.1)^IS1^NOY^tJ1235545^IULSC2606964^IKMARC^aA(OCoLC)843784993^IF2014^Fv3000000^^O
```
Required fields: IQ - call number (selcallnum -oD), tJ - cat key, IU - flex key.

Repository Information:
-----------------------
This product is under version control using Git.
[Visit GitHub](https://github.com/Edmonton-Public-Library)

Dependencies:
-------------
None

Known Issues:
-------------
None
