namespace PawUtau.Engine;

/// <summary>Single-thread TaskScheduler that plays the role of OpenUtau's UI thread (DocManager's main thread).</summary>
public sealed class PumpScheduler : TaskScheduler, IDisposable
{
    readonly System.Collections.Concurrent.BlockingCollection<Task> queue = new();
    public Thread Thread { get; }

    public PumpScheduler()
    {
        Thread = new Thread(() =>
        {
            foreach (var t in queue.GetConsumingEnumerable()) TryExecuteTask(t);
        }) { IsBackground = true, Name = "paw-utau-main" };
        Thread.Start();
    }

    protected override void QueueTask(Task task) => queue.Add(task);
    protected override bool TryExecuteTaskInline(Task task, bool prev) => Thread.CurrentThread == Thread && TryExecuteTask(task);
    protected override IEnumerable<Task> GetScheduledTasks() => queue.ToArray();

    public bool OnPump => Thread.CurrentThread == Thread;
    public void Post(Action a) => Task.Factory.StartNew(a, CancellationToken.None, TaskCreationOptions.None, this);

    /// <summary>Run on the pump and wait. Must not be called from the pump thread itself.</summary>
    public T Invoke<T>(Func<T> f)
    {
        if (OnPump) return f();
        return Task.Factory.StartNew(f, CancellationToken.None, TaskCreationOptions.None, this).GetAwaiter().GetResult();
    }
    public void Invoke(Action a) => Invoke<int>(() => { a(); return 0; });
    public void Dispose() => queue.CompleteAdding();
}
