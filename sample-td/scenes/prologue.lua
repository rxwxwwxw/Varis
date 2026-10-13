-- The first arrival: the new Warden climbs to Marrow Hill with a key and a letter. The scene ends
-- at the first dusk, with the stage left to the hub.

scene prologue {
    {kind=:background, tag=:terraces},
    {kind=:narration, text="Marrow Hill is built in terraces on a steep hillside, and every terrace is lit. Below the last of them the valley is a lake of fog, and nothing in the fog has ever been seen to stop moving."},
    {kind=:narration, text="You arrive with an old key and a letter. The letter says that the last Warden is gone, and that a lantern burns brightest for people who are trusted."},
    {kind=:show, character=:ilse, slot=:left},
    {kind=:say, character=:ilse, text="You are the Warden? I was told to expect a person, not a coat on a stick. I am Ilse. I trim the lamps and I mend what breaks."},
    {kind=:show, character=:corvin, slot=:right},
    {kind=:say, character=:corvin, attributes={expression=:fierce}, text="Captain Corvin, retired. I know the roads. Whether you will let me tell you about them is the question."},
    {kind=:narration, text="Ilse sets down her can of oil. Corvin does not sit down at all."},
    {kind=:say, character=:ilse, text="Dusk is the hour. The Dim climbs the switchbacks towards the Lantern, and the Lantern burns only while somebody is minding it."},
    {kind=:say, character=:corvin, text="Build where the road turns. A lamp that cannot see the road is a candle."},
    {kind=:narration, text="Far below, the fog moves. It is not wind."},
    {kind=:effect, name=:start_dusk},
    {kind="return"},
}
