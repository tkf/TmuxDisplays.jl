using Logging
using ProgressLogging
using TerminalLoggers
using TmuxDisplays
using UnicodePlots

d = tmuxdisplay(Text("This is the default tmux display"))
sleep(0.8)

smalldisplay = TmuxDisplays.split_window(size = 3, target = d)
display(smalldisplay, Text("This is a custom tmux display"))
sleep(0.8)

with_logger(TerminalLogger(IO(smalldisplay))) do
    @withprogress name = "Level 1" for i in 1:3
        plt = scatterplot(randn(10), randn(10), xlim = (-3, 3), ylim = (-3, 3))
        @withprogress name = "Level 2" for j in 1:30
            sleep(0.01)
            tmuxdisplay(scatterplot!(plt, randn(10), randn(10)))
            @logprogress j / 30
        end
        @logprogress i / 3
    end
end
