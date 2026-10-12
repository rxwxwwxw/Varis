-- Harbour Window: a linear visual novel, with engine-owned stage state.
character mira {
    name = "Mira", tag = :mira,
    attributes = { expression = {:quiet, :smile}, outfit = {:coat} },
    defaults = { expression = :quiet, outfit = :coat }
}
scene farewell {
    {kind=:say, character=:mira, id="farewell.promise", text="Then I will see you tomorrow."},
    {kind="return"}
}
scene harbour {
    {kind=:background, tag=:harbour_evening},
    {kind=:audio, channel=:music, tag=:evening_theme},
    {kind=:show, character=:mira, slot=:left},
    {kind=:input, ["local"]="visitor", text="What is your name?"},
    {kind=:say, character=:mira, attributes={expression=:smile}, id="harbour.welcome", text="Welcome back, {visitor}."},
    {kind=:call, target=:farewell},
    {kind=:say, character=:mira, id="harbour.lantern", text="Leave the lantern burning."},
    {kind=:hide, character=:mira},
    {kind=:audio, channel=:music},
    {kind=:ended}
}
