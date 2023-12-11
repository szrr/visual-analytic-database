select DISTANCE(f_feature, EXTRACTION(path"/home/szr/frames.png")) as DIS
from FRAMES
order by DIS
limit 50
;