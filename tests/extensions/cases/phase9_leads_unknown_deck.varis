-- A choice may only lead to a declared deck.
relation open(1)
fact open(:x)
deck :default {draw = 1, replacement = true}
storylet door()
    when { open(:x) }
    title "Door"
    choice down
        leads :nowhere
        title "Go"
        effect do end
    end
end
reject(function() narrative.seal() end, "nowhere")
