param(
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

$ProjectRoot = $PSScriptRoot
$ProbeScript = Join-Path $ProjectRoot "passbolt_api_probe.py"
$InventoryScript = Join-Path $ProjectRoot "passbolt_app.py"
$ReviewScript = Join-Path $ProjectRoot "passbolt_review.py"
$ImportScript = Join-Path $ProjectRoot "passbolt_import.py"
$CryptoScript = Join-Path $ProjectRoot "passbolt_crypto.mjs"
$BundledPython = Join-Path $env:USERPROFILE ".cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe"
$BundledNode = Join-Path $env:USERPROFILE ".cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe"

if (Test-Path -LiteralPath $BundledPython -PathType Leaf) {
    $PythonExecutable = $BundledPython
} elseif (Get-Command python -ErrorAction SilentlyContinue) {
    $PythonExecutable = (Get-Command python).Source
} elseif (Get-Command py -ErrorAction SilentlyContinue) {
    $PythonExecutable = (Get-Command py).Source
} else {
    throw "Python non trovato. Installare Python 3.11 o superiore."
}

if (Test-Path -LiteralPath $BundledNode -PathType Leaf) {
    $NodeExecutable = $BundledNode
} elseif (Get-Command node -ErrorAction SilentlyContinue) {
    $NodeExecutable = (Get-Command node).Source
} else {
    throw "Node.js non trovato. Installare Node.js 18 o superiore."
}

[xml]$Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Passbolt Migration Assistant - v0.12.5"
        Width="1240" Height="800" MinWidth="1080" MinHeight="700"
        WindowStartupLocation="CenterScreen" Background="#F4F6F8"
        FontFamily="Segoe UI">
    <Window.Resources>
        <SolidColorBrush x:Key="TextBrush" Color="#1F2933" />
        <SolidColorBrush x:Key="MutedBrush" Color="#66737F" />
        <Style x:Key="PrimaryButton" TargetType="Button">
            <Setter Property="Background" Value="#2878D0" />
            <Setter Property="Foreground" Value="White" />
            <Setter Property="FontWeight" Value="SemiBold" />
            <Setter Property="Padding" Value="18,10" />
            <Setter Property="BorderThickness" Value="0" />
            <Setter Property="Cursor" Value="Hand" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}" CornerRadius="4" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" />
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#1D63AE" /></Trigger>
                <Trigger Property="IsEnabled" Value="False"><Setter Property="Background" Value="#A9BAC9" /></Trigger>
            </Style.Triggers>
        </Style>
        <Style x:Key="SecondaryButton" TargetType="Button" BasedOn="{StaticResource PrimaryButton}">
            <Setter Property="Background" Value="#EAF0F5" />
            <Setter Property="Foreground" Value="#1F2933" />
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#DDE8F0" /></Trigger>
                <Trigger Property="IsEnabled" Value="False"><Setter Property="Background" Value="#EDF1F4" /><Setter Property="Foreground" Value="#98A5B1" /></Trigger>
            </Style.Triggers>
        </Style>
        <Style x:Key="Card" TargetType="Border">
            <Setter Property="Background" Value="White" />
            <Setter Property="BorderBrush" Value="#DDE3E8" />
            <Setter Property="BorderThickness" Value="1" />
            <Setter Property="CornerRadius" Value="5" />
            <Setter Property="Padding" Value="20,16" />
            <Setter Property="Margin" Value="0,0,0,12" />
        </Style>
        <Style TargetType="TextBox">
            <Setter Property="BorderBrush" Value="#C9D3DB" />
            <Setter Property="BorderThickness" Value="1" />
            <Setter Property="Padding" Value="10,8" />
            <Setter Property="Background" Value="#FAFBFC" />
            <Setter Property="Foreground" Value="#1F2933" />
            <Setter Property="VerticalContentAlignment" Value="Center" />
        </Style>
        <Style TargetType="PasswordBox">
            <Setter Property="BorderBrush" Value="#C9D3DB" />
            <Setter Property="BorderThickness" Value="1" />
            <Setter Property="Padding" Value="10,8" />
            <Setter Property="Background" Value="#FAFBFC" />
            <Setter Property="Foreground" Value="#1F2933" />
            <Setter Property="VerticalContentAlignment" Value="Center" />
        </Style>
        <Style TargetType="ComboBox">
            <Setter Property="BorderBrush" Value="#C9D3DB" />
            <Setter Property="BorderThickness" Value="1" />
            <Setter Property="Padding" Value="8,7" />
            <Setter Property="Background" Value="#FAFBFC" />
            <Setter Property="Foreground" Value="#1F2933" />
        </Style>
        <Style TargetType="DataGrid">
            <Setter Property="Background" Value="White" />
            <Setter Property="BorderBrush" Value="#DDE3E8" />
            <Setter Property="RowBackground" Value="White" />
            <Setter Property="AlternatingRowBackground" Value="#F8FAFB" />
            <Setter Property="HorizontalGridLinesBrush" Value="#E8EDF1" />
            <Setter Property="VerticalGridLinesBrush" Value="#E8EDF1" />
            <Setter Property="HeadersVisibility" Value="Column" />
            <Setter Property="CanUserAddRows" Value="False" />
            <Setter Property="CanUserDeleteRows" Value="False" />
            <Setter Property="IsReadOnly" Value="True" />
        </Style>
    </Window.Resources>

    <Grid>
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="226" />
            <ColumnDefinition Width="*" />
        </Grid.ColumnDefinitions>

        <Grid Grid.Column="0" Background="#18212A">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto" />
                <RowDefinition Height="*" />
                <RowDefinition Height="Auto" />
            </Grid.RowDefinitions>
            <StackPanel Margin="22,26,22,32">
                <TextBlock Text="Passbolt" Foreground="White" FontSize="25" FontWeight="Bold" />
                <TextBlock Text="Migration Assistant" Foreground="#AEB8C2" FontSize="12" Margin="0,2,0,0" />
            </StackPanel>
            <StackPanel Grid.Row="1" Margin="10,0">
                <Border x:Name="StepConfiguration" Background="#263746" CornerRadius="4" Padding="14,12" Margin="0,2" Cursor="Hand">
                    <StackPanel Orientation="Horizontal"><TextBlock x:Name="StepConfigurationNumber" Text="01" Foreground="#62A8EA" FontWeight="Bold" Width="32" /><TextBlock x:Name="StepConfigurationText" Text="Configurazione" Foreground="White" FontWeight="SemiBold" /></StackPanel>
                </Border>
                <Border x:Name="StepInventory" Padding="14,12" Margin="0,2" CornerRadius="4" Cursor="Hand">
                    <StackPanel Orientation="Horizontal"><TextBlock x:Name="StepInventoryNumber" Text="02" Foreground="#667683" FontWeight="Bold" Width="32" /><TextBlock x:Name="StepInventoryText" Text="Inventario file" Foreground="#8795A1" /></StackPanel>
                </Border>
                <Border x:Name="StepReview" Padding="14,12" Margin="0,2" CornerRadius="4" Cursor="Hand"><StackPanel Orientation="Horizontal"><TextBlock x:Name="StepReviewNumber" Text="03" Foreground="#667683" FontWeight="Bold" Width="32" /><TextBlock x:Name="StepReviewText" Text="Revisione" Foreground="#667683" /></StackPanel></Border>
                <Border x:Name="StepImport" Padding="14,12" Margin="0,2" CornerRadius="4" Cursor="Hand"><StackPanel Orientation="Horizontal"><TextBlock x:Name="StepImportNumber" Text="04" Foreground="#667683" FontWeight="Bold" Width="32" /><TextBlock x:Name="StepImportText" Text="Importazione" Foreground="#667683" /></StackPanel></Border>
            </StackPanel>
            <Border Grid.Row="2" Background="#202C36" CornerRadius="5" Padding="14" Margin="14,18">
                <StackPanel>
                    <TextBlock Text="MODALIT&#xC0; SICURA" Foreground="#72D6B0" FontSize="11" FontWeight="Bold" />
                    <TextBlock x:Name="SafeModeText" Text="L&#x2019;inventario usa soltanto metadati. Il contenuto dei documenti non viene aperto." Foreground="#D6DEE5" FontSize="11" TextWrapping="Wrap" Margin="0,5,0,0" />
                </StackPanel>
            </Border>
        </Grid>

        <Grid Grid.Column="1">
            <ScrollViewer x:Name="ConfigurationPage" VerticalScrollBarVisibility="Auto">
                <Grid Margin="32,28">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto" />
                        <RowDefinition Height="Auto" />
                        <RowDefinition Height="Auto" />
                        <RowDefinition Height="Auto" />
                    </Grid.RowDefinitions>
                    <Grid Grid.Row="0" Margin="0,0,0,22">
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
                        <StackPanel>
                            <TextBlock Text="Configurazione" FontSize="27" FontWeight="Bold" Foreground="#1F2933" />
                            <TextBlock Text="Verifica l&#x2019;istanza Passbolt e indica la cartella principale dei documenti clienti." Foreground="#66737F" FontSize="13" Margin="0,4,0,0" />
                        </StackPanel>
                        <Border Grid.Column="1" Background="#E5F6EF" CornerRadius="4" Padding="12,7" VerticalAlignment="Center">
                            <TextBlock Text="DRY-RUN ATTIVO" Foreground="#16875D" FontSize="11" FontWeight="Bold" />
                        </Border>
                    </Grid>

                    <Border Grid.Row="1" Style="{StaticResource Card}" Padding="24,20">
                        <StackPanel>
                            <TextBlock Text="1. Connessione Passbolt" FontSize="16" FontWeight="SemiBold" Foreground="#1F2933" />
                            <TextBlock Text="Inserisci l'URL. L'app rileva la fingerprint OpenPGP del server e ne richiede la conferma prima di procedere; il controllo pubblico non esegue alcun login." Foreground="#66737F" Margin="0,4,0,14" TextWrapping="Wrap" />
                            <Grid>
                                <Grid.ColumnDefinitions><ColumnDefinition Width="*" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
                                <TextBox x:Name="PassboltUrl" ToolTip="URL base HTTPS, ad esempio https://passbolt.example.com" />
                                <Button x:Name="VerifyButton" Grid.Column="1" Content="Verifica connessione" Style="{StaticResource PrimaryButton}" Margin="12,0,0,0" />
                            </Grid>
                            <Grid Margin="0,10,0,0">
                                <Grid.ColumnDefinitions><ColumnDefinition Width="150" /><ColumnDefinition Width="*" /></Grid.ColumnDefinitions>
                                <TextBlock Text="Fingerprint rilevata" Foreground="#66737F" VerticalAlignment="Center" />
                                <Border Grid.Column="1" Background="#F3F6F8" BorderBrush="#D7DEE4" BorderThickness="1" CornerRadius="4" Padding="10,7">
                                    <TextBlock x:Name="DetectedFingerprint" Text="Non ancora rilevata" Foreground="#43515D" FontFamily="Consolas" TextWrapping="Wrap" />
                                </Border>
                            </Grid>
                            <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
                                <Ellipse x:Name="ConnectionDot" Width="9" Height="9" Fill="#98A5B1" Margin="0,0,7,0" />
                                <TextBlock x:Name="ConnectionStatus" Text="Non verificata" Foreground="#66737F" />
                            </StackPanel>
                        </StackPanel>
                    </Border>

                    <Border Grid.Row="2" Style="{StaticResource Card}" Padding="24,20">
                        <StackPanel>
                            <TextBlock Text="2. Cartella documenti clienti" FontSize="16" FontWeight="SemiBold" Foreground="#1F2933" />
                            <TextBlock Text="Ogni cartella di primo livello viene considerata un cliente. I file nella radice restano separati." Foreground="#66737F" Margin="0,4,0,14" />
                            <Grid>
                                <Grid.ColumnDefinitions><ColumnDefinition Width="*" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
                                <TextBox x:Name="ClientFolder" />
                                <Button x:Name="BrowseButton" Grid.Column="1" Content="Scegli cartella" Style="{StaticResource SecondaryButton}" Margin="12,0,0,0" />
                            </Grid>
                            <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
                                <Ellipse x:Name="FolderDot" Width="9" Height="9" Fill="#98A5B1" Margin="0,0,7,0" />
                                <TextBlock x:Name="FolderStatus" Text="Nessuna cartella selezionata" Foreground="#66737F" />
                            </StackPanel>
                        </StackPanel>
                    </Border>

                    <Grid Grid.Row="3" Margin="0,4,0,0">
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
                        <StackPanel VerticalAlignment="Center">
                            <CheckBox Content="Modalit&#xE0; simulazione obbligatoria" IsChecked="True" IsEnabled="False" />
                            <TextBlock Text="La fase successiva raccoglie esclusivamente metadati dei file." Foreground="#66737F" FontSize="11" Margin="0,4,0,0" />
                        </StackPanel>
                        <Button x:Name="ContinueButton" Grid.Column="1" Content="Continua all&#x2019;inventario  &#x2192;" Style="{StaticResource PrimaryButton}" IsEnabled="False" Padding="22,12" />
                    </Grid>
                </Grid>
            </ScrollViewer>

            <Grid x:Name="InventoryPage" Visibility="Collapsed" Margin="28,22,28,22">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto" />
                    <RowDefinition Height="Auto" />
                    <RowDefinition Height="Auto" />
                    <RowDefinition Height="*" />
                    <RowDefinition Height="Auto" />
                </Grid.RowDefinitions>

                <Grid Grid.Row="0" Margin="0,0,0,16">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*" /><ColumnDefinition Width="Auto" /><ColumnDefinition Width="Auto" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
                    <StackPanel>
                        <TextBlock Text="Inventario file" FontSize="27" FontWeight="Bold" Foreground="#1F2933" />
                        <TextBlock x:Name="InventoryRoot" Text="Inventario non ancora eseguito" Foreground="#66737F" FontSize="12" Margin="0,4,0,0" TextTrimming="CharacterEllipsis" />
                    </StackPanel>
                    <Button x:Name="RefreshButton" Grid.Column="1" Content="Aggiorna inventario" Style="{StaticResource SecondaryButton}" VerticalAlignment="Center" />
                    <Button x:Name="ExportButton" Grid.Column="2" Content="Esporta CSV" Style="{StaticResource SecondaryButton}" Margin="8,0,0,0" VerticalAlignment="Center" IsEnabled="False" />
                    <Button x:Name="ReviewSelectionButton" Grid.Column="3" Content="Rivedi selezionati (0)" Style="{StaticResource PrimaryButton}" Margin="8,0,0,0" VerticalAlignment="Center" IsEnabled="False" />
                </Grid>

                <Grid Grid.Row="1" Margin="0,0,0,12">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*" /><ColumnDefinition Width="*" /><ColumnDefinition Width="*" /><ColumnDefinition Width="*" /></Grid.ColumnDefinitions>
                    <Border Grid.Column="0" Style="{StaticResource Card}" Margin="0,0,5,0"><StackPanel><TextBlock Text="Clienti individuati" Foreground="#66737F" /><TextBlock x:Name="MetricClients" Text="&#x2014;" FontSize="24" FontWeight="Bold" Foreground="#1F2933" /></StackPanel></Border>
                    <Border Grid.Column="1" Style="{StaticResource Card}" Margin="5,0"><StackPanel><TextBlock Text="File supportati" Foreground="#66737F" /><TextBlock x:Name="MetricFiles" Text="&#x2014;" FontSize="24" FontWeight="Bold" Foreground="#1F2933" /></StackPanel></Border>
                    <Border Grid.Column="2" Style="{StaticResource Card}" Margin="5,0"><StackPanel><TextBlock Text="Dimensione indicizzata" Foreground="#66737F" /><TextBlock x:Name="MetricSize" Text="&#x2014;" FontSize="24" FontWeight="Bold" Foreground="#1F2933" /></StackPanel></Border>
                    <Border Grid.Column="3" Style="{StaticResource Card}" Margin="5,0,0,0"><StackPanel><TextBlock Text="File ignorati" Foreground="#66737F" /><TextBlock x:Name="MetricIgnored" Text="&#x2014;" FontSize="24" FontWeight="Bold" Foreground="#1F2933" /></StackPanel></Border>
                </Grid>

                <Border Grid.Row="2" Style="{StaticResource Card}" Padding="14,12">
                    <Grid>
                        <Grid.ColumnDefinitions><ColumnDefinition Width="180" /><ColumnDefinition Width="160" /><ColumnDefinition Width="*" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
                        <ComboBox x:Name="ClientFilter" Grid.Column="0" />
                        <ComboBox x:Name="FormatFilter" Grid.Column="1" Margin="8,0,0,0" />
                        <TextBox x:Name="SearchBox" Grid.Column="2" Margin="8,0,0,0" ToolTip="Cerca nel cliente o nel percorso relativo" />
                        <TextBlock x:Name="FilterStatus" Grid.Column="3" Text="0 file" Foreground="#66737F" VerticalAlignment="Center" Margin="14,0,0,0" />
                    </Grid>
                </Border>

                <Border Grid.Row="3" Style="{StaticResource Card}" Margin="0" Padding="0">
                    <Grid>
                        <Grid.RowDefinitions><RowDefinition Height="*" /><RowDefinition Height="Auto" /></Grid.RowDefinitions>
                        <DataGrid x:Name="FilesGrid" Grid.Row="0" AutoGenerateColumns="False" AlternationCount="2" SelectionMode="Extended" SelectionUnit="FullRow" ToolTip="Seleziona pi&#xF9; file con Ctrl o Maiusc" VirtualizingPanel.IsVirtualizing="True" VirtualizingPanel.VirtualizationMode="Recycling">
                            <DataGrid.Columns>
                                <DataGridTextColumn Header="Cliente" Binding="{Binding Client}" Width="145" />
                                <DataGridTextColumn Header="Percorso relativo" Binding="{Binding RelativePath}" Width="*" />
                                <DataGridTextColumn Header="Formato" Binding="{Binding Extension}" Width="78" />
                                <DataGridTextColumn Header="Categoria" Binding="{Binding Category}" Width="118" />
                                <DataGridTextColumn Header="Dimensione" Binding="{Binding Size}" Width="92" />
                                <DataGridTextColumn Header="Modificato" Binding="{Binding Modified}" Width="132" />
                            </DataGrid.Columns>
                        </DataGrid>
                        <Border x:Name="WarningsPanel" Grid.Row="1" Background="#FFF8E7" BorderBrush="#E5C36A" BorderThickness="0,1,0,0" Padding="12,8" Visibility="Collapsed">
                            <TextBlock x:Name="WarningsText" Foreground="#765B17" FontSize="11" TextWrapping="Wrap" />
                        </Border>
                    </Grid>
                </Border>

                <Grid Grid.Row="4" Margin="0,12,0,0">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto" /><ColumnDefinition Width="*" /></Grid.ColumnDefinitions>
                    <Button x:Name="BackButton" Content="&#x2190;  Torna alla configurazione" Style="{StaticResource SecondaryButton}" />
                    <TextBox x:Name="ActivityLog" Grid.Column="1" Margin="12,0,0,0" Height="42" IsReadOnly="True" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" FontFamily="Consolas" FontSize="10" Background="#EEF2F5" BorderThickness="0" />
                </Grid>
            </Grid>

            <Grid x:Name="ReviewPage" Visibility="Collapsed" Margin="28,22,28,22">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto" />
                    <RowDefinition Height="Auto" />
                    <RowDefinition Height="Auto" />
                    <RowDefinition Height="*" />
                    <RowDefinition Height="Auto" />
                </Grid.RowDefinitions>

                <Grid Grid.Row="0" Margin="0,0,0,16">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
                    <StackPanel>
                        <TextBlock Text="Revisione controllata" FontSize="27" FontWeight="Bold" Foreground="#1F2933" />
                        <TextBlock x:Name="ReviewSummary" Text="Nessuna revisione eseguita" Foreground="#66737F" FontSize="12" Margin="0,4,0,0" />
                    </StackPanel>
                    <Border Grid.Column="1" Background="#E5F6EF" CornerRadius="4" Padding="12,7" VerticalAlignment="Center">
                        <TextBlock x:Name="ReviewPasswordState" Text="PASSWORD MASCHERATE" Foreground="#16875D" FontSize="11" FontWeight="Bold" />
                    </Border>
                </Grid>

                <Grid Grid.Row="1" Margin="0,0,0,12">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*" /><ColumnDefinition Width="*" /><ColumnDefinition Width="*" /><ColumnDefinition Width="*" /></Grid.ColumnDefinitions>
                    <Border Grid.Column="0" Style="{StaticResource Card}" Margin="0,0,5,0"><StackPanel><TextBlock Text="File analizzati" Foreground="#66737F" /><TextBlock x:Name="ReviewMetricFiles" Text="&#x2014;" FontSize="24" FontWeight="Bold" Foreground="#1F2933" /></StackPanel></Border>
                    <Border Grid.Column="1" Style="{StaticResource Card}" Margin="5,0"><StackPanel><TextBlock Text="Candidati" Foreground="#66737F" /><TextBlock x:Name="ReviewMetricCandidates" Text="&#x2014;" FontSize="24" FontWeight="Bold" Foreground="#1F2933" /></StackPanel></Border>
                    <Border Grid.Column="2" Style="{StaticResource Card}" Margin="5,0"><StackPanel><TextBlock Text="Pronti" Foreground="#66737F" /><TextBlock x:Name="ReviewMetricReady" Text="&#x2014;" FontSize="24" FontWeight="Bold" Foreground="#16875D" /></StackPanel></Border>
                    <Border Grid.Column="3" Style="{StaticResource Card}" Margin="5,0,0,0"><StackPanel><TextBlock Text="Da completare" Foreground="#66737F" /><TextBlock x:Name="ReviewMetricIncomplete" Text="&#x2014;" FontSize="24" FontWeight="Bold" Foreground="#B7791F" /></StackPanel></Border>
                </Grid>

                <Border Grid.Row="2" Style="{StaticResource Card}" Padding="14,12">
                    <Grid>
                        <Grid.ColumnDefinitions><ColumnDefinition Width="170" /><ColumnDefinition Width="*" /><ColumnDefinition Width="Auto" /><ColumnDefinition Width="Auto" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
                        <ComboBox x:Name="ReviewStatusFilter" Grid.Column="0" />
                        <TextBox x:Name="ReviewSearchBox" Grid.Column="1" Margin="8,0,0,0" ToolTip="Cerca in cliente, titolo, username, URL o origine" />
                        <ToggleButton x:Name="ReviewPasswordToggle" Grid.Column="2" Content="Mostra password" Margin="8,0,0,0" Padding="12,7" VerticalAlignment="Stretch" ToolTip="Mostra temporaneamente le password dei candidati caricandole soltanto in memoria" />
                        <Button x:Name="EditReviewCandidateButton" Grid.Column="3" Content="Modifica..." Style="{StaticResource SecondaryButton}" Margin="8,0,0,0" Padding="14,7" IsEnabled="False" ToolTip="Modifica il candidato selezionato prima dell'importazione" />
                        <TextBlock x:Name="ReviewFilterStatus" Grid.Column="4" Text="0 candidati" Foreground="#66737F" VerticalAlignment="Center" Margin="14,0,0,0" />
                    </Grid>
                </Border>

                <Border Grid.Row="3" Style="{StaticResource Card}" Margin="0" Padding="0">
                    <Grid>
                        <Grid.RowDefinitions><RowDefinition Height="*" /><RowDefinition Height="Auto" /></Grid.RowDefinitions>
                        <DataGrid x:Name="ReviewCandidatesGrid" Grid.Row="0" AutoGenerateColumns="False" AlternationCount="2" SelectionMode="Extended" SelectionUnit="FullRow" ToolTip="Seleziona fino a 25 candidati pronti con Ctrl o Maiusc" VirtualizingPanel.IsVirtualizing="True" VirtualizingPanel.VirtualizationMode="Recycling">
                            <DataGrid.Columns>
                                <DataGridTextColumn Header="Stato" Binding="{Binding StatusLabel}" Width="105" />
                                <DataGridTextColumn Header="Cliente" Binding="{Binding Client}" Width="125" />
                                <DataGridTextColumn Header="Titolo" Binding="{Binding Title}" Width="150" />
                                <DataGridTextColumn Header="Username" Binding="{Binding Username}" Width="135" />
                                <DataGridTextColumn Header="URL / host" Binding="{Binding Uri}" Width="*" />
                                <DataGridTextColumn Header="Password" Binding="{Binding SecretDisplay}" Width="130" />
                                <DataGridTextColumn Header="Origine" Binding="{Binding Source}" Width="180" />
                            </DataGrid.Columns>
                        </DataGrid>
                        <Border x:Name="ReviewWarningsPanel" Grid.Row="1" Background="#FFF8E7" BorderBrush="#E5C36A" BorderThickness="0,1,0,0" Padding="12,8" Visibility="Collapsed">
                            <TextBlock x:Name="ReviewWarningsText" Foreground="#765B17" FontSize="11" TextWrapping="Wrap" MaxHeight="62" />
                        </Border>
                    </Grid>
                </Border>

                <Grid Grid.Row="4" Margin="0,12,0,0">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto" /><ColumnDefinition Width="*" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
                    <Button x:Name="ReviewBackButton" Content="&#x2190;  Torna all&#x2019;inventario" Style="{StaticResource SecondaryButton}" />
                    <TextBlock Grid.Column="1" Text="Le password sono mascherate per impostazione predefinita; quando richieste restano solo in memoria e non vengono salvate o registrate." Foreground="#66737F" FontSize="11" VerticalAlignment="Center" Margin="14,0" TextWrapping="Wrap" />
                    <Button x:Name="PrepareImportButton" Grid.Column="2" Content="Prepara importazione (0)" Style="{StaticResource PrimaryButton}" IsEnabled="False" />
                </Grid>
            </Grid>

            <Grid x:Name="ImportPage" Visibility="Collapsed" Margin="28,22,28,22">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto" />
                    <RowDefinition Height="Auto" />
                    <RowDefinition Height="Auto" />
                    <RowDefinition Height="*" />
                    <RowDefinition Height="Auto" />
                </Grid.RowDefinitions>

                <Grid Grid.Row="0" Margin="0,0,0,14">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
                    <StackPanel>
                        <TextBlock Text="Importazione controllata" FontSize="27" FontWeight="Bold" Foreground="#1F2933" />
                        <TextBlock x:Name="ImportSummary" Text="Prepara i candidati dalla revisione" Foreground="#66737F" FontSize="12" Margin="0,4,0,0" />
                    </StackPanel>
                    <Border Grid.Column="1" Background="#E5F6EF" CornerRadius="4" Padding="12,7" VerticalAlignment="Center">
                        <TextBlock Text="GPGAuth + OPENPGP LOCALE" Foreground="#16875D" FontSize="11" FontWeight="Bold" />
                    </Border>
                </Grid>

                <Border Grid.Row="1" Background="#EAF4FE" BorderBrush="#A8C9EA" BorderThickness="1" CornerRadius="5" Padding="14,10" Margin="0,0,0,12">
                    <TextBlock Text="Avvia la sessione una sola volta con chiave privata, passphrase e MFA. L'identita OpenPGP e la sessione Passbolt restano esclusivamente in memoria e vengono riutilizzate per dry-run e importazioni successive; si chiudono su richiesta, alla chiusura dell'app o dopo 30 minuti di inattivita." Foreground="#284F75" FontSize="11" TextWrapping="Wrap" />
                </Border>

                <Border Grid.Row="2" Style="{StaticResource Card}" Padding="18,14">
                    <Grid>
                        <Grid.RowDefinitions><RowDefinition Height="Auto" /><RowDefinition Height="Auto" /><RowDefinition Height="Auto" /><RowDefinition Height="Auto" /><RowDefinition Height="Auto" /><RowDefinition Height="Auto" /><RowDefinition Height="Auto" /><RowDefinition Height="Auto" /></Grid.RowDefinitions>
                        <Grid.ColumnDefinitions><ColumnDefinition Width="150" /><ColumnDefinition Width="*" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
                        <TextBlock Grid.Row="0" Grid.ColumnSpan="3" Text="Identit&#xE0; OpenPGP" FontSize="15" FontWeight="SemiBold" Foreground="#1F2933" Margin="0,0,0,10" />
                        <TextBlock Grid.Row="1" Grid.Column="0" Text="Chiave privata" Foreground="#66737F" VerticalAlignment="Center" />
                        <TextBox x:Name="PrivateKeyPath" Grid.Row="1" Grid.Column="1" ToolTip="File ASCII-armored della chiave privata Passbolt" />
                        <Button x:Name="BrowseKeyButton" Grid.Row="1" Grid.Column="2" Content="Scegli file" Style="{StaticResource SecondaryButton}" Margin="10,0,0,0" />
                        <TextBlock Grid.Row="2" Grid.Column="0" Text="Passphrase" Foreground="#66737F" VerticalAlignment="Center" Margin="0,9,0,0" />
                        <PasswordBox x:Name="KeyPassphrase" Grid.Row="2" Grid.Column="1" Margin="0,9,0,0" ToolTip="Usata solo per aprire la sessione; non viene salvata e il campo viene subito cancellato" />
                        <TextBlock Grid.Row="3" Grid.Column="0" Text="Codice MFA (TOTP)" Foreground="#66737F" VerticalAlignment="Center" Margin="0,9,0,0" />
                        <PasswordBox x:Name="MfaTotpCode" Grid.Row="3" Grid.Column="1" Margin="0,9,0,0" MaxLength="6" ToolTip="Usato solo per aprire la sessione; non viene salvato e il campo viene subito cancellato" />
                        <Button x:Name="ImportSessionButton" Grid.Row="3" Grid.Column="2" Content="Avvia sessione" Style="{StaticResource SecondaryButton}" Margin="10,9,0,0" />
                        <TextBlock Grid.Row="4" Grid.Column="0" Text="Destinazione" Foreground="#66737F" VerticalAlignment="Center" Margin="0,9,0,0" />
                        <ComboBox x:Name="DestinationMode" Grid.Row="4" Grid.Column="1" Margin="0,9,0,0" SelectedIndex="0" ToolTip="Crea o riutilizza una cartella per ogni cliente; in un contenitore condiviso eredita la maschera dei permessi verificata">
                            <ComboBoxItem Content="Cartelle per cliente nel contenitore scelto" Tag="client_folders" />
                            <ComboBoxItem Content="Mappatura distinta per ogni cliente" Tag="client_mapping" />
                            <ComboBoxItem Content="Direttamente nella cartella scelta" Tag="direct_folder" />
                            <ComboBoxItem Content="Radice personale Passbolt" Tag="root" />
                        </ComboBox>
                        <TextBlock Grid.Row="5" Grid.Column="0" Text="Cartella Passbolt" Foreground="#66737F" VerticalAlignment="Center" Margin="0,9,0,0" />
                        <ComboBox x:Name="DestinationFolder" Grid.Row="5" Grid.Column="1" Margin="0,9,0,0" SelectedIndex="0" MaxDropDownHeight="300" ToolTip="Il primo dry-run carica le cartelle Passbolt accessibili">
                            <ComboBoxItem Content="Radice personale Passbolt" Tag="" />
                        </ComboBox>
                        <Button x:Name="ConfigureClientMappingsButton" Grid.Row="5" Grid.Column="1" Grid.ColumnSpan="2" HorizontalAlignment="Left" Content="Mappa clienti" Style="{StaticResource SecondaryButton}" Margin="0,9,0,0" IsEnabled="False" Visibility="Collapsed" />
                        <TextBlock Grid.Row="6" Grid.Column="0" Text="Formato cartelle" Foreground="#66737F" VerticalAlignment="Center" Margin="0,9,0,0" />
                        <ComboBox x:Name="FolderFormat" Grid.Row="6" Grid.Column="1" Margin="0,9,0,0" SelectedIndex="0" ToolTip="Automatico usa il formato predefinito; le nuove cartelle in un contenitore condiviso ne ereditano i permessi">
                            <ComboBoxItem Content="Automatico (predefinito server)" Tag="auto" />
                            <ComboBoxItem Content="v4 - nome in chiaro" Tag="v4" />
                            <ComboBoxItem Content="v5 - nome cifrato" Tag="v5" />
                        </ComboBox>
                        <TextBlock Grid.Row="7" Grid.Column="0" Text="Formato risorse" Foreground="#66737F" VerticalAlignment="Center" Margin="0,9,0,0" />
                        <ComboBox x:Name="ResourceFormat" Grid.Row="7" Grid.Column="1" Margin="0,9,0,0" SelectedIndex="0" ToolTip="Automatico usa il formato predefinito dall'istanza Passbolt">
                            <ComboBoxItem Content="Automatico (predefinito server)" Tag="auto" />
                            <ComboBoxItem Content="v4 - metadati in chiaro" Tag="v4" />
                            <ComboBoxItem Content="v5 - metadati cifrati" Tag="v5" />
                        </ComboBox>
                        <Button x:Name="DryRunButton" Grid.Row="7" Grid.Column="2" Content="Verifica e dry-run" Style="{StaticResource PrimaryButton}" Margin="10,9,0,0" IsEnabled="False" />
                    </Grid>
                </Border>

                <Grid Grid.Row="3">
                    <Grid.RowDefinitions><RowDefinition Height="Auto" /><RowDefinition Height="*" /></Grid.RowDefinitions>
                    <Grid Grid.Row="0" Margin="0,0,0,10">
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*" /><ColumnDefinition Width="*" /><ColumnDefinition Width="*" /><ColumnDefinition Width="*" /></Grid.ColumnDefinitions>
                        <Border Grid.Column="0" Style="{StaticResource Card}" Margin="0,0,5,0"><StackPanel><TextBlock Text="Selezionati" Foreground="#66737F" /><TextBlock x:Name="ImportMetricSelected" Text="&#x2014;" FontSize="22" FontWeight="Bold" Foreground="#1F2933" /></StackPanel></Border>
                        <Border Grid.Column="1" Style="{StaticResource Card}" Margin="5,0"><StackPanel><TextBlock Text="Da creare" Foreground="#66737F" /><TextBlock x:Name="ImportMetricCreate" Text="&#x2014;" FontSize="22" FontWeight="Bold" Foreground="#16875D" /></StackPanel></Border>
                        <Border Grid.Column="2" Style="{StaticResource Card}" Margin="5,0"><StackPanel><TextBlock Text="Duplicati esatti" Foreground="#66737F" /><TextBlock x:Name="ImportMetricDuplicates" Text="&#x2014;" FontSize="22" FontWeight="Bold" Foreground="#B7791F" /></StackPanel></Border>
                        <Border Grid.Column="3" Style="{StaticResource Card}" Margin="5,0,0,0"><StackPanel><TextBlock Text="Cartelle nuove" Foreground="#66737F" /><TextBlock x:Name="ImportMetricExisting" Text="&#x2014;" FontSize="22" FontWeight="Bold" Foreground="#1F2933" /></StackPanel></Border>
                    </Grid>
                    <Border Grid.Row="1" Style="{StaticResource Card}" Margin="0" Padding="0">
                        <Grid>
                            <Grid.RowDefinitions><RowDefinition Height="Auto" /><RowDefinition Height="*" /><RowDefinition Height="Auto" /></Grid.RowDefinitions>
                            <Border Grid.Row="0" Background="#F8FAFB" BorderBrush="#E3E8EC" BorderThickness="0,0,0,1" Padding="12,9">
                                <TextBlock x:Name="ImportIdentity" Text="Eseguire il dry-run per verificare identit&#xE0; e piano." Foreground="#66737F" FontSize="11" TextWrapping="Wrap" />
                            </Border>
                            <DataGrid x:Name="ImportPlanGrid" Grid.Row="1" AutoGenerateColumns="False" AlternationCount="2" SelectionMode="Single" VirtualizingPanel.IsVirtualizing="True" VirtualizingPanel.VirtualizationMode="Recycling">
                                <DataGrid.Columns>
                                    <DataGridTextColumn Header="Azione" Binding="{Binding ActionLabel}" Width="205" />
                                    <DataGridTextColumn Header="Destinazione" Binding="{Binding Destination}" Width="190" />
                                    <DataGridTextColumn Header="Titolo" Binding="{Binding Title}" Width="165" />
                                    <DataGridTextColumn Header="Username" Binding="{Binding Username}" Width="150" />
                                    <DataGridTextColumn Header="URL / host" Binding="{Binding Uri}" Width="*" />
                                </DataGrid.Columns>
                            </DataGrid>
                            <Border Grid.Row="2" Background="#FFF8E7" BorderBrush="#E5C36A" BorderThickness="0,1,0,0" Padding="12,8">
                                <TextBlock x:Name="ImportPlanStatus" Text="Nessuna richiesta sar&#xE0; inviata finch&#xE9; non viene avviato il dry-run." Foreground="#765B17" FontSize="11" TextWrapping="Wrap" />
                            </Border>
                        </Grid>
                    </Border>
                </Grid>

                <Grid Grid.Row="4" Margin="0,12,0,0">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto" /><ColumnDefinition Width="*" /><ColumnDefinition Width="260" /><ColumnDefinition Width="Auto" /></Grid.ColumnDefinitions>
                    <Button x:Name="ImportBackButton" Content="&#x2190;  Torna alla revisione" Style="{StaticResource SecondaryButton}" />
                    <TextBlock x:Name="ConfirmationHint" Grid.Column="1" Text="Prima esegui il dry-run." Foreground="#66737F" FontSize="11" VerticalAlignment="Center" Margin="14,0" TextWrapping="Wrap" />
                    <TextBox x:Name="ImportConfirmation" Grid.Column="2" IsEnabled="False" ToolTip="Digita la frase di conferma esatta" Margin="6,0" />
                    <Button x:Name="ExecuteImportButton" Grid.Column="3" Content="Importa in Passbolt" Style="{StaticResource PrimaryButton}" IsEnabled="False" Margin="8,0,0,0" />
                </Grid>
            </Grid>
        </Grid>
    </Grid>
</Window>
'@

$Reader = New-Object System.Xml.XmlNodeReader $Xaml
$Window = [Windows.Markup.XamlReader]::Load($Reader)

function Get-Control([string]$Name) {
    $Control = $Window.FindName($Name)
    if ($null -eq $Control) { throw "Controllo UI mancante: $Name" }
    return $Control
}

$ConfigurationPage = Get-Control "ConfigurationPage"
$InventoryPage = Get-Control "InventoryPage"
$ReviewPage = Get-Control "ReviewPage"
$StepConfiguration = Get-Control "StepConfiguration"
$StepConfigurationNumber = Get-Control "StepConfigurationNumber"
$StepConfigurationText = Get-Control "StepConfigurationText"
$StepInventory = Get-Control "StepInventory"
$StepInventoryNumber = Get-Control "StepInventoryNumber"
$StepInventoryText = Get-Control "StepInventoryText"
$StepReview = Get-Control "StepReview"
$StepReviewNumber = Get-Control "StepReviewNumber"
$StepReviewText = Get-Control "StepReviewText"
$StepImport = Get-Control "StepImport"
$StepImportNumber = Get-Control "StepImportNumber"
$StepImportText = Get-Control "StepImportText"
$SafeModeText = Get-Control "SafeModeText"
$PassboltUrl = Get-Control "PassboltUrl"
$DetectedFingerprint = Get-Control "DetectedFingerprint"
$VerifyButton = Get-Control "VerifyButton"
$ConnectionDot = Get-Control "ConnectionDot"
$ConnectionStatus = Get-Control "ConnectionStatus"
$ClientFolder = Get-Control "ClientFolder"
$BrowseButton = Get-Control "BrowseButton"
$FolderDot = Get-Control "FolderDot"
$FolderStatus = Get-Control "FolderStatus"
$ContinueButton = Get-Control "ContinueButton"
$InventoryRoot = Get-Control "InventoryRoot"
$RefreshButton = Get-Control "RefreshButton"
$ExportButton = Get-Control "ExportButton"
$ReviewSelectionButton = Get-Control "ReviewSelectionButton"
$MetricClients = Get-Control "MetricClients"
$MetricFiles = Get-Control "MetricFiles"
$MetricSize = Get-Control "MetricSize"
$MetricIgnored = Get-Control "MetricIgnored"
$ClientFilter = Get-Control "ClientFilter"
$FormatFilter = Get-Control "FormatFilter"
$SearchBox = Get-Control "SearchBox"
$FilterStatus = Get-Control "FilterStatus"
$FilesGrid = Get-Control "FilesGrid"
$WarningsPanel = Get-Control "WarningsPanel"
$WarningsText = Get-Control "WarningsText"
$BackButton = Get-Control "BackButton"
$ActivityLog = Get-Control "ActivityLog"
$ReviewSummary = Get-Control "ReviewSummary"
$ReviewMetricFiles = Get-Control "ReviewMetricFiles"
$ReviewMetricCandidates = Get-Control "ReviewMetricCandidates"
$ReviewMetricReady = Get-Control "ReviewMetricReady"
$ReviewMetricIncomplete = Get-Control "ReviewMetricIncomplete"
$ReviewPasswordState = Get-Control "ReviewPasswordState"
$ReviewStatusFilter = Get-Control "ReviewStatusFilter"
$ReviewSearchBox = Get-Control "ReviewSearchBox"
$ReviewPasswordToggle = Get-Control "ReviewPasswordToggle"
$EditReviewCandidateButton = Get-Control "EditReviewCandidateButton"
$ReviewFilterStatus = Get-Control "ReviewFilterStatus"
$ReviewCandidatesGrid = Get-Control "ReviewCandidatesGrid"
$ReviewWarningsPanel = Get-Control "ReviewWarningsPanel"
$ReviewWarningsText = Get-Control "ReviewWarningsText"
$ReviewBackButton = Get-Control "ReviewBackButton"
$PrepareImportButton = Get-Control "PrepareImportButton"
$ImportPage = Get-Control "ImportPage"
$ImportSummary = Get-Control "ImportSummary"
$PrivateKeyPath = Get-Control "PrivateKeyPath"
$BrowseKeyButton = Get-Control "BrowseKeyButton"
$KeyPassphrase = Get-Control "KeyPassphrase"
$MfaTotpCode = Get-Control "MfaTotpCode"
$ImportSessionButton = Get-Control "ImportSessionButton"
$DestinationMode = Get-Control "DestinationMode"
$DestinationFolder = Get-Control "DestinationFolder"
$ConfigureClientMappingsButton = Get-Control "ConfigureClientMappingsButton"
$FolderFormat = Get-Control "FolderFormat"
$ResourceFormat = Get-Control "ResourceFormat"
$DryRunButton = Get-Control "DryRunButton"
$ImportMetricSelected = Get-Control "ImportMetricSelected"
$ImportMetricCreate = Get-Control "ImportMetricCreate"
$ImportMetricDuplicates = Get-Control "ImportMetricDuplicates"
$ImportMetricExisting = Get-Control "ImportMetricExisting"
$ImportIdentity = Get-Control "ImportIdentity"
$ImportPlanGrid = Get-Control "ImportPlanGrid"
$ImportPlanStatus = Get-Control "ImportPlanStatus"
$ImportBackButton = Get-Control "ImportBackButton"
$ConfirmationHint = Get-Control "ConfirmationHint"
$ImportConfirmation = Get-Control "ImportConfirmation"
$ExecuteImportButton = Get-Control "ExecuteImportButton"

$script:ConnectionVerified = $false
$script:VerifiedUrl = ""
$script:VerifiedFingerprint = ""
$script:InventoryResult = $null
$script:InventoryFolder = ""
$script:AllInventoryRows = @()
$script:ReviewResult = $null
$script:AllReviewRows = @()
$script:ReviewFilePasswords = @{}
$script:ReviewPasswordsVisible = $false
$script:UpdatingReviewPasswordToggle = $false
$script:ImportCandidates = @()
$script:ImportSecretOverrides = @{}
$script:ImportSourceFilePasswords = @{}
$script:ImportPlan = $null
$script:ImportPlanKeyPath = ""
$script:ImportCompleted = $false
$script:ImportSessionProcess = $null
$script:ImportSessionErrorTask = $null
$script:ImportSessionId = ""
$script:ImportSessionInfo = $null
$script:ImportSessionLastActivityUtc = [DateTime]::MinValue
$script:ImportSessionRoot = ""
$script:ImportSessionKeyPath = ""
$script:ImportSessionIdleTimeoutMinutes = 30
$script:ClosingApplication = $false
$script:PopulatingDestinationFolders = $false
$script:AvailableDestinationFolders = @()
$script:DestinationFolderCatalogLoaded = $false
$script:ClientDestinationMap = @{}
$script:CurrentPage = "Configuration"

function Get-Brush([string]$Color) {
    return [Windows.Media.BrushConverter]::new().ConvertFromString($Color)
}

function Add-Activity([string]$Message) {
    $Timestamp = Get-Date -Format "HH:mm:ss"
    if ($ActivityLog.Text) { $ActivityLog.AppendText([Environment]::NewLine) }
    $ActivityLog.AppendText("[$Timestamp] $Message")
    $ActivityLog.ScrollToEnd()
}

function Update-Ui {
    [System.Windows.Forms.Application]::DoEvents()
}

function Format-Size([long]$Bytes) {
    $Size = [double]$Bytes
    foreach ($Unit in @("B", "KB", "MB", "GB", "TB")) {
        if ($Size -lt 1024 -or $Unit -eq "TB") {
            if ($Unit -eq "B") { return "{0:N0} {1}" -f $Size, $Unit }
            return "{0:N1} {1}" -f $Size, $Unit
        }
        $Size /= 1024
    }
}

function Invoke-PythonJson([string]$Script, [string[]]$Arguments) {
    $Output = & $PythonExecutable $Script @Arguments 2>&1
    $ExitCode = $LASTEXITCODE
    $Text = ($Output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    if ($ExitCode -ne 0) { throw $Text }
    return $Text | ConvertFrom-Json
}

function ConvertTo-ProcessArgument([string]$Value) {
    if ($null -eq $Value -or $Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $Builder = New-Object System.Text.StringBuilder
    [void]$Builder.Append('"')
    $Backslashes = 0
    foreach ($Character in $Value.ToCharArray()) {
        if ($Character -eq '\') {
            $Backslashes++
            continue
        }
        if ($Character -eq '"') {
            [void]$Builder.Append(('\' * (($Backslashes * 2) + 1)))
            [void]$Builder.Append('"')
            $Backslashes = 0
            continue
        }
        if ($Backslashes -gt 0) {
            [void]$Builder.Append(('\' * $Backslashes))
            $Backslashes = 0
        }
        [void]$Builder.Append($Character)
    }
    if ($Backslashes -gt 0) { [void]$Builder.Append(('\' * ($Backslashes * 2))) }
    [void]$Builder.Append('"')
    return $Builder.ToString()
}

function Invoke-SecureJsonProcess(
    [string]$Executable,
    [string[]]$Arguments,
    [object]$InputObject,
    [int]$TimeoutMilliseconds = 180000
) {
    $StartInfo = New-Object System.Diagnostics.ProcessStartInfo
    $StartInfo.FileName = $Executable
    $QuotedArguments = @($Arguments | ForEach-Object { ConvertTo-ProcessArgument ([string]$_) })
    $StartInfo.Arguments = $QuotedArguments -join ' '
    $StartInfo.UseShellExecute = $false
    $StartInfo.CreateNoWindow = $true
    $StartInfo.RedirectStandardInput = $true
    $StartInfo.RedirectStandardOutput = $true
    $StartInfo.RedirectStandardError = $true
    $StartInfo.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $StartInfo.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)

    $Process = New-Object System.Diagnostics.Process
    $Process.StartInfo = $StartInfo
    $Payload = $InputObject | ConvertTo-Json -Depth 14 -Compress
    try {
        if (-not $Process.Start()) { throw "Impossibile avviare la procedura locale protetta." }
        $OutputTask = $Process.StandardOutput.ReadToEndAsync()
        $ErrorTask = $Process.StandardError.ReadToEndAsync()
        $PayloadBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Payload)
        $Process.StandardInput.BaseStream.Write($PayloadBytes, 0, $PayloadBytes.Length)
        $Process.StandardInput.BaseStream.Flush()
        $Process.StandardInput.Close()
        $PayloadBytes = $null
        $Payload = $null
        $PayloadBytes = $null
        if (-not $Process.WaitForExit($TimeoutMilliseconds)) {
            try { $Process.Kill() } catch {}
            throw "Timeout della procedura locale protetta."
        }
        $Output = $OutputTask.Result
        $IgnoredErrorOutput = $ErrorTask.Result
        if ([string]::IsNullOrWhiteSpace($Output)) {
            throw "La procedura locale protetta non ha restituito un risultato valido."
        }
        try {
            $Envelope = $Output | ConvertFrom-Json
        } catch {
            throw "La procedura locale protetta ha restituito dati non validi."
        }
        if ($null -eq $Envelope -or -not ($Envelope.PSObject.Properties.Name -contains "ok")) {
            throw "La procedura locale protetta ha restituito una struttura inattesa."
        }
        return $Envelope
    } finally {
        $Payload = $null
        if ($null -ne $Process) { $Process.Dispose() }
    }
}

function Test-ImportSessionActive {
    if ($null -eq $script:ImportSessionProcess -or -not $script:ImportSessionId) { return $false }
    try {
        return -not $script:ImportSessionProcess.HasExited
    } catch {
        return $false
    }
}

function Start-ImportSessionProcess {
    if ($null -ne $script:ImportSessionProcess) {
        Stop-ImportSession "" $false
    }
    if (-not (Test-Path -LiteralPath $script:InventoryFolder -PathType Container)) {
        throw "La cartella clienti della sessione non e' disponibile."
    }

    $StartInfo = New-Object System.Diagnostics.ProcessStartInfo
    $StartInfo.FileName = $PythonExecutable
    $Arguments = @(
        $ImportScript,
        "--session",
        "--root", $script:InventoryFolder,
        "--node", $NodeExecutable,
        "--crypto-script", $CryptoScript
    )
    $StartInfo.Arguments = (@($Arguments | ForEach-Object { ConvertTo-ProcessArgument ([string]$_) }) -join ' ')
    $StartInfo.WorkingDirectory = $ProjectRoot
    $StartInfo.UseShellExecute = $false
    $StartInfo.CreateNoWindow = $true
    $StartInfo.RedirectStandardInput = $true
    $StartInfo.RedirectStandardOutput = $true
    $StartInfo.RedirectStandardError = $true
    $StartInfo.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $StartInfo.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)

    $Process = New-Object System.Diagnostics.Process
    $Process.StartInfo = $StartInfo
    try {
        if (-not $Process.Start()) { throw "Impossibile avviare la sessione locale protetta." }
        $script:ImportSessionProcess = $Process
        $script:ImportSessionErrorTask = $Process.StandardError.ReadToEndAsync()
    } catch {
        $Process.Dispose()
        throw
    }
}

function Invoke-ImportSessionJson(
    [object]$InputObject,
    [int]$TimeoutMilliseconds = 180000
) {
    if (-not (Test-ImportSessionActive) -and [string]$InputObject.command -ne "session-open") {
        throw "La sessione sicura di importazione non e' attiva."
    }
    if ($null -eq $script:ImportSessionProcess) {
        throw "Il coordinatore della sessione sicura non e' disponibile."
    }
    try {
        if ($script:ImportSessionProcess.HasExited) {
            throw "La sessione sicura locale si e' chiusa inaspettatamente."
        }
    } catch {
        throw "La sessione sicura locale non e' piu disponibile."
    }

    $Payload = $InputObject | ConvertTo-Json -Depth 14 -Compress
    if ($Payload.Length -gt 8388608) {
        throw "La richiesta della sessione sicura e' troppo grande."
    }
    $PayloadBytes = $null
    try {
        $OutputTask = $script:ImportSessionProcess.StandardOutput.ReadLineAsync()
        $PayloadBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Payload + "`n")
        $script:ImportSessionProcess.StandardInput.BaseStream.Write($PayloadBytes, 0, $PayloadBytes.Length)
        $script:ImportSessionProcess.StandardInput.BaseStream.Flush()
        if (-not $OutputTask.Wait($TimeoutMilliseconds)) {
            try { $script:ImportSessionProcess.Kill() } catch {}
            throw "Timeout della sessione sicura locale."
        }
        $Output = $OutputTask.Result
        if ([string]::IsNullOrWhiteSpace($Output) -or $Output.Length -gt 8388608) {
            throw "La sessione sicura locale non ha restituito un risultato valido."
        }
        try {
            $Envelope = $Output | ConvertFrom-Json
        } catch {
            throw "La sessione sicura locale ha restituito dati non validi."
        }
        if ($null -eq $Envelope -or -not ($Envelope.PSObject.Properties.Name -contains "ok")) {
            throw "La sessione sicura locale ha restituito una struttura inattesa."
        }
        $script:ImportSessionLastActivityUtc = [DateTime]::UtcNow
        return $Envelope
    } catch {
        try {
            if ($null -ne $script:ImportSessionProcess -and -not $script:ImportSessionProcess.HasExited) {
                $script:ImportSessionProcess.Kill()
                [void]$script:ImportSessionProcess.WaitForExit(5000)
            }
        } catch {}
        throw
    } finally {
        $Payload = $null
        $PayloadBytes = $null
    }
}

function Get-ImportSessionIdentityText {
    if (-not (Test-ImportSessionActive) -or $null -eq $script:ImportSessionInfo) {
        return "Avviare la sessione sicura per verificare identita' e piano."
    }
    $Info = $script:ImportSessionInfo
    $DisplayName = ("$($Info.user.first_name) $($Info.user.last_name)").Trim()
    if (-not $DisplayName) { $DisplayName = [string]$Info.user.username }
    return "Sessione attiva: $DisplayName <$($Info.user.username)> | chiave $($Info.user_key_fingerprint) | $($Info.authentication) | timeout inattivita $($script:ImportSessionIdleTimeoutMinutes) min"
}

function Update-ImportSessionState {
    $Active = Test-ImportSessionActive
    $PrivateKeyPath.IsEnabled = -not $Active
    $BrowseKeyButton.IsEnabled = -not $Active
    $KeyPassphrase.IsEnabled = -not $Active
    $MfaTotpCode.IsEnabled = -not $Active
    if ($Active) {
        $ImportSessionButton.Content = "Chiudi sessione"
        $ImportSessionButton.IsEnabled = $true
        $DryRunButton.IsEnabled = ($script:ConnectionVerified -and $script:ImportCandidates.Count -gt 0 -and $script:ImportSessionRoot -eq $script:InventoryFolder)
        if ($null -eq $script:ImportPlan) { $ImportIdentity.Text = Get-ImportSessionIdentityText }
    } else {
        $ImportSessionButton.Content = "Avvia sessione"
        $ImportSessionButton.IsEnabled = ($script:ConnectionVerified -and $script:ImportCandidates.Count -gt 0 -and (Test-Path -LiteralPath $script:InventoryFolder -PathType Container))
        $DryRunButton.IsEnabled = $false
        if ($null -eq $script:ImportPlan) { $ImportIdentity.Text = "Avviare la sessione sicura per verificare identita' e piano." }
    }
    Update-ExecuteImportState
}

function Stop-ImportSession(
    [string]$Reason = "",
    [bool]$ResetPlan = $true
) {
    $Process = $script:ImportSessionProcess
    $SessionId = $script:ImportSessionId
    if ($null -ne $Process) {
        try {
            if (-not $Process.HasExited -and $SessionId) {
                $CloseRequest = [pscustomobject][ordered]@{
                    command = "session-close"
                    session_id = $SessionId
                }
                try { [void](Invoke-ImportSessionJson $CloseRequest 10000) } catch {}
            }
            try { $Process.StandardInput.Close() } catch {}
            if (-not $Process.HasExited -and -not $Process.WaitForExit(10000)) {
                try { $Process.Kill() } catch {}
                try { [void]$Process.WaitForExit(5000) } catch {}
            }
        } finally {
            $Process.Dispose()
        }
    }
    $script:ImportSessionProcess = $null
    $script:ImportSessionErrorTask = $null
    $script:ImportSessionId = ""
    $script:ImportSessionInfo = $null
    $script:ImportSessionLastActivityUtc = [DateTime]::MinValue
    $script:ImportSessionRoot = ""
    $script:ImportSessionKeyPath = ""
    $KeyPassphrase.Clear()
    $MfaTotpCode.Clear()
    if ($ResetPlan) {
        $Status = if ($Reason) { $Reason } else { "Sessione chiusa. Avviare una nuova sessione prima del dry-run." }
        Reset-ImportPlan $Status
    }
    Update-ImportSessionState
    if ($Reason -and -not $script:ClosingApplication) { Add-Activity $Reason }
}

function Test-TerminalImportSessionError($Envelope) {
    if ($null -eq $Envelope -or $null -eq $Envelope.error) { return $false }
    $Code = [string]$Envelope.error.code
    return $Code -in @(
        "IMPORT_SESSION_EXPIRED",
        "IMPORT_SESSION_MFA_EXPIRED",
        "IMPORT_SESSION_NOT_OPEN",
        "IMPORT_SESSION_ID_MISMATCH",
        "IMPORT_SESSION_IDENTITY_CHANGED"
    )
}

function Open-ImportSession {
    if (-not $script:ConnectionVerified -or -not $script:VerifiedUrl -or -not $script:VerifiedFingerprint) {
        [System.Windows.MessageBox]::Show("La connessione Passbolt non e' verificata. Tornare alla configurazione.", "Connessione non verificata", "OK", "Warning") | Out-Null
        return
    }
    if ($script:ImportCandidates.Count -lt 1 -or -not (Test-Path -LiteralPath $script:InventoryFolder -PathType Container)) {
        [System.Windows.MessageBox]::Show("Preparare prima almeno un candidato pronto dalla revisione.", "Importazione non preparata", "OK", "Warning") | Out-Null
        return
    }
    $KeyPath = $PrivateKeyPath.Text.Trim()
    if (-not (Test-Path -LiteralPath $KeyPath -PathType Leaf)) {
        [System.Windows.MessageBox]::Show("Selezionare un file di chiave privata OpenPGP accessibile.", "Chiave privata mancante", "OK", "Warning") | Out-Null
        return
    }
    if ($KeyPassphrase.Password.Length -lt 1) {
        [System.Windows.MessageBox]::Show("Inserire la passphrase della chiave privata.", "Passphrase mancante", "OK", "Warning") | Out-Null
        return
    }
    if ($MfaTotpCode.Password.Length -gt 0 -and $MfaTotpCode.Password -notmatch '^\d{6}$') {
        [System.Windows.MessageBox]::Show("Il codice MFA TOTP deve contenere esattamente 6 cifre.", "Codice MFA non valido", "OK", "Warning") | Out-Null
        return
    }

    $Passphrase = $KeyPassphrase.Password
    $MfaCode = $MfaTotpCode.Password
    $KeyPassphrase.Clear()
    $MfaTotpCode.Clear()
    $OpenRequest = $null
    $ImportSessionButton.IsEnabled = $false
    $ImportPlanStatus.Text = "Apertura della sessione autenticata in corso..."
    Add-Activity "Avvio sessione autenticata GPGAuth per il workflow di importazione."
    Update-Ui
    try {
        Start-ImportSessionProcess
        $OpenRequest = [pscustomobject][ordered]@{
            command = "session-open"
            base_url = $script:VerifiedUrl
            expected_server_fingerprint = $script:VerifiedFingerprint
            private_key_path = $KeyPath
            passphrase = $Passphrase
            mfa_totp = $MfaCode
        }
        $Envelope = Invoke-ImportSessionJson $OpenRequest
        if (-not [bool]$Envelope.ok) { throw (Get-SecureErrorMessage $Envelope) }
        if (-not [string]$Envelope.result.session_id) { throw "La sessione autenticata non ha restituito un identificatore valido." }
        $script:ImportSessionId = [string]$Envelope.result.session_id
        $script:ImportSessionInfo = $Envelope.result
        $script:ImportSessionRoot = $script:InventoryFolder
        $script:ImportSessionKeyPath = $KeyPath
        $script:ImportSessionLastActivityUtc = [DateTime]::UtcNow
        Reset-ImportPlan "Sessione autenticata attiva. Configurare la destinazione ed eseguire il dry-run."
        Add-Activity "Sessione autenticata aperta; passphrase e MFA non saranno richiesti di nuovo durante questa sessione."
    } catch {
        $FailureMessage = [string]$_.Exception.Message
        Stop-ImportSession "" $false
        Reset-ImportPlan "Apertura sessione non riuscita. Nessuna credenziale e' stata conservata."
        Add-Activity "Apertura sessione non riuscita: $FailureMessage"
        [System.Windows.MessageBox]::Show($FailureMessage, "Sessione non avviata", "OK", "Error") | Out-Null
    } finally {
        if ($null -ne $OpenRequest) {
            $OpenRequest.passphrase = $null
            $OpenRequest.mfa_totp = $null
        }
        $OpenRequest = $null
        $Passphrase = $null
        $MfaCode = $null
        $KeyPassphrase.Clear()
        $MfaTotpCode.Clear()
        Update-ImportSessionState
    }
}

function Get-SecureErrorMessage($Envelope) {
    if ($null -ne $Envelope -and $null -ne $Envelope.error -and $Envelope.error.message) {
        return [string]$Envelope.error.message
    }
    return "Operazione protetta non riuscita."
}

function Reset-ImportPlan([string]$Status = "Eseguire il dry-run per preparare un nuovo piano.") {
    $script:ImportPlan = $null
    $script:ImportPlanKeyPath = ""
    $script:ImportCompleted = $false
    $ImportPlanGrid.ItemsSource = $null
    $ImportMetricCreate.Text = [string][char]0x2014
    $ImportMetricDuplicates.Text = [string][char]0x2014
    $ImportMetricExisting.Text = [string][char]0x2014
    $ImportIdentity.Text = Get-ImportSessionIdentityText
    $ImportPlanStatus.Text = $Status
    $ImportConfirmation.Text = ""
    $ImportConfirmation.IsEnabled = $false
    $ConfirmationHint.Text = if (Test-ImportSessionActive) { "Sessione attiva: eseguire il dry-run." } else { "Prima avviare la sessione sicura." }
    $ExecuteImportButton.IsEnabled = $false
}

function Get-SelectedDestinationFolderId {
    if ($null -eq $DestinationFolder.SelectedItem) { return "" }
    return [string]$DestinationFolder.SelectedItem.Tag
}

function Get-RequiredImportClients {
    $ClientsByKey = @{}
    foreach ($Candidate in @($script:ImportCandidates)) {
        $Client = [string]$Candidate.client
        $Key = $Client.Trim().ToLowerInvariant()
        if ($Key -and -not $ClientsByKey.ContainsKey($Key)) {
            $ClientsByKey[$Key] = $Client
        }
    }
    return @($ClientsByKey.Values | Sort-Object)
}

function Get-ClientDestinationMappingPayload {
    $Entries = New-Object System.Collections.Generic.List[object]
    foreach ($Client in @(Get-RequiredImportClients)) {
        if (-not $script:ClientDestinationMap.ContainsKey($Client)) { continue }
        $Value = [string]$script:ClientDestinationMap[$Client]
        if (-not $Value -or $Value -eq "__unassigned__") { continue }
        $FolderId = if ($Value -eq "__root__") { $null } else { $Value }
        $Entries.Add([pscustomobject][ordered]@{
            client = $Client
            folder_id = $FolderId
        })
    }
    return $Entries.ToArray()
}

function Update-ClientMappingButtonState {
    $Clients = @(Get-RequiredImportClients)
    $Configured = 0
    $AvailableIds = @{}
    foreach ($Folder in @($script:AvailableDestinationFolders)) {
        $AvailableIds[[string]$Folder.id] = $true
    }
    foreach ($Client in $Clients) {
        if (-not $script:ClientDestinationMap.ContainsKey($Client)) { continue }
        $Value = [string]$script:ClientDestinationMap[$Client]
        if ($Value -eq "__root__" -or ($Value -and $AvailableIds.ContainsKey($Value))) {
            $Configured++
        }
    }
    $Mode = if ($null -ne $DestinationMode.SelectedItem) { [string]$DestinationMode.SelectedItem.Tag } else { "" }
    $IsMapping = ($Mode -eq "client_mapping")
    $ConfigureClientMappingsButton.Visibility = if ($IsMapping) { "Visible" } else { "Collapsed" }
    $ConfigureClientMappingsButton.IsEnabled = ($IsMapping -and $script:DestinationFolderCatalogLoaded -and $Clients.Count -gt 0)
    if (-not $script:DestinationFolderCatalogLoaded) {
        $ConfigureClientMappingsButton.Content = "Prima carica le cartelle"
    } else {
        $ConfigureClientMappingsButton.Content = "Mappa clienti ($Configured/$($Clients.Count))"
    }
}

function Update-DestinationControlState {
    $Mode = [string]$DestinationMode.SelectedItem.Tag
    $DestinationFolder.IsEnabled = ($Mode -in @("client_folders", "direct_folder"))
    $DestinationFolder.Visibility = if ($Mode -eq "client_mapping") { "Collapsed" } else { "Visible" }
    $FolderFormat.IsEnabled = ($Mode -eq "client_folders")
    Update-ClientMappingButtonState
}

function Get-DestinationFolderDisplayText($Folder) {
    if ($null -eq $Folder) { return "" }
    $Label = [string]$Folder.path
    if ([bool]$Folder.shared) {
        $Label += " [Condivisa: $([int]$Folder.share_recipient_count) destinatari]"
    }
    return $Label
}

function Update-DestinationFolderOptions($Folders, [string]$SelectedId = "", [bool]$CatalogLoaded = $true) {
    $script:AvailableDestinationFolders = @($Folders)
    $script:DestinationFolderCatalogLoaded = $CatalogLoaded
    $script:PopulatingDestinationFolders = $true
    try {
        $DestinationFolder.Items.Clear()
        $RootItem = New-Object System.Windows.Controls.ComboBoxItem
        $RootItem.Content = "Radice personale Passbolt"
        $RootItem.Tag = ""
        [void]$DestinationFolder.Items.Add($RootItem)
        $SelectedIndex = 0
        foreach ($Folder in @($Folders)) {
            $Item = New-Object System.Windows.Controls.ComboBoxItem
            $Item.Content = Get-DestinationFolderDisplayText $Folder
            $Item.Tag = [string]$Folder.id
            $Item.ToolTip = if ([bool]$Folder.shared) {
                "Cartella condivisa | destinatari: $([int]$Folder.share_recipient_count) | permessi: $([int]$Folder.share_permission_count) | ID: $($Folder.id)"
            } else {
                "Cartella personale | ID: $($Folder.id)"
            }
            [void]$DestinationFolder.Items.Add($Item)
            if ([string]$Folder.id -eq $SelectedId) {
                $SelectedIndex = $DestinationFolder.Items.Count - 1
            }
        }
        $DestinationFolder.SelectedIndex = $SelectedIndex
    } finally {
        $script:PopulatingDestinationFolders = $false
    }
    Update-DestinationControlState
}

function Show-ClientDestinationMappingDialog([switch]$BuildOnly) {
    if (-not $script:DestinationFolderCatalogLoaded) {
        [System.Windows.MessageBox]::Show("Eseguire prima il dry-run per caricare le cartelle Passbolt accessibili.", "Cartelle non caricate", "OK", "Information") | Out-Null
        return
    }
    $Clients = @(Get-RequiredImportClients)
    if ($Clients.Count -lt 1) { return }

    $Dialog = New-Object System.Windows.Window
    $Dialog.Title = "Mappatura clienti - Passbolt"
    $Dialog.Width = 820
    $Dialog.Height = [Math]::Min(700, 230 + ($Clients.Count * 50))
    $Dialog.MinWidth = 660
    $Dialog.MinHeight = 320
    $Dialog.WindowStartupLocation = "CenterOwner"
    if (-not $BuildOnly -and $Window.IsVisible) { $Dialog.Owner = $Window }
    $Dialog.Background = Get-Brush "#F4F6F8"
    $Dialog.FontFamily = "Segoe UI"

    $Layout = New-Object System.Windows.Controls.Grid
    $Layout.Margin = [System.Windows.Thickness]::new(20)
    $HeaderRow = New-Object System.Windows.Controls.RowDefinition
    $HeaderRow.Height = [System.Windows.GridLength]::Auto
    $ContentRow = New-Object System.Windows.Controls.RowDefinition
    $ContentRow.Height = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
    $FooterRow = New-Object System.Windows.Controls.RowDefinition
    $FooterRow.Height = [System.Windows.GridLength]::Auto
    [void]$Layout.RowDefinitions.Add($HeaderRow)
    [void]$Layout.RowDefinitions.Add($ContentRow)
    [void]$Layout.RowDefinitions.Add($FooterRow)

    $Header = New-Object System.Windows.Controls.StackPanel
    $Header.Margin = [System.Windows.Thickness]::new(0, 0, 0, 14)
    $Title = New-Object System.Windows.Controls.TextBlock
    $Title.Text = "Destinazione Passbolt per ogni cliente"
    $Title.FontSize = 20
    $Title.FontWeight = "Bold"
    $Title.Foreground = Get-Brush "#1F2933"
    [void]$Header.Children.Add($Title)
    $Description = New-Object System.Windows.Controls.TextBlock
    $Description.Text = "Ogni cliente deve essere associato esplicitamente a una cartella scrivibile o alla radice. Per le cartelle condivise verranno ereditati i permessi e cifrata una copia del segreto per ogni destinatario verificato."
    $Description.TextWrapping = "Wrap"
    $Description.Foreground = Get-Brush "#66737F"
    $Description.Margin = [System.Windows.Thickness]::new(0, 5, 0, 0)
    [void]$Header.Children.Add($Description)
    [System.Windows.Controls.Grid]::SetRow($Header, 0)
    [void]$Layout.Children.Add($Header)

    $Border = New-Object System.Windows.Controls.Border
    $Border.Background = Get-Brush "#FFFFFF"
    $Border.BorderBrush = Get-Brush "#DDE3E8"
    $Border.BorderThickness = [System.Windows.Thickness]::new(1)
    $Border.CornerRadius = [System.Windows.CornerRadius]::new(5)
    $Border.Padding = [System.Windows.Thickness]::new(12)
    [System.Windows.Controls.Grid]::SetRow($Border, 1)
    $Scroll = New-Object System.Windows.Controls.ScrollViewer
    $Scroll.VerticalScrollBarVisibility = "Auto"
    $Rows = New-Object System.Windows.Controls.StackPanel
    $Editors = @{}
    foreach ($Client in $Clients) {
        $Row = New-Object System.Windows.Controls.Grid
        $Row.Margin = [System.Windows.Thickness]::new(0, 4, 0, 4)
        $ClientColumn = New-Object System.Windows.Controls.ColumnDefinition
        $ClientColumn.Width = [System.Windows.GridLength]::new(220)
        $FolderColumn = New-Object System.Windows.Controls.ColumnDefinition
        $FolderColumn.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
        [void]$Row.ColumnDefinitions.Add($ClientColumn)
        [void]$Row.ColumnDefinitions.Add($FolderColumn)

        $ClientLabel = New-Object System.Windows.Controls.TextBlock
        $ClientLabel.Text = $Client
        $ClientLabel.VerticalAlignment = "Center"
        $ClientLabel.FontWeight = "SemiBold"
        $ClientLabel.Foreground = Get-Brush "#1F2933"
        $ClientLabel.ToolTip = $Client
        [System.Windows.Controls.Grid]::SetColumn($ClientLabel, 0)
        [void]$Row.Children.Add($ClientLabel)

        $Combo = New-Object System.Windows.Controls.ComboBox
        $Combo.MinWidth = 360
        $Combo.MaxDropDownHeight = 320
        $Combo.Margin = [System.Windows.Thickness]::new(12, 0, 0, 0)
        $UnassignedItem = New-Object System.Windows.Controls.ComboBoxItem
        $UnassignedItem.Content = "Selezionare una destinazione..."
        $UnassignedItem.Tag = "__unassigned__"
        [void]$Combo.Items.Add($UnassignedItem)
        $RootItem = New-Object System.Windows.Controls.ComboBoxItem
        $RootItem.Content = "Radice personale Passbolt"
        $RootItem.Tag = "__root__"
        [void]$Combo.Items.Add($RootItem)
        $SelectedIndex = 0
        $CurrentValue = if ($script:ClientDestinationMap.ContainsKey($Client)) { [string]$script:ClientDestinationMap[$Client] } else { "" }
        if ($CurrentValue -eq "__root__") { $SelectedIndex = 1 }
        foreach ($Folder in @($script:AvailableDestinationFolders)) {
            $Item = New-Object System.Windows.Controls.ComboBoxItem
            $Item.Content = Get-DestinationFolderDisplayText $Folder
            $Item.Tag = [string]$Folder.id
            $Item.ToolTip = if ([bool]$Folder.shared) {
                "Cartella condivisa | destinatari: $([int]$Folder.share_recipient_count) | permessi: $([int]$Folder.share_permission_count) | ID: $($Folder.id)"
            } else {
                "Cartella personale | ID: $($Folder.id)"
            }
            [void]$Combo.Items.Add($Item)
            if ([string]$Folder.id -eq $CurrentValue) {
                $SelectedIndex = $Combo.Items.Count - 1
            }
        }
        $Combo.SelectedIndex = $SelectedIndex
        [System.Windows.Controls.Grid]::SetColumn($Combo, 1)
        [void]$Row.Children.Add($Combo)
        $Editors[$Client] = $Combo
        [void]$Rows.Children.Add($Row)
    }
    $Scroll.Content = $Rows
    $Border.Child = $Scroll
    [void]$Layout.Children.Add($Border)

    $Footer = New-Object System.Windows.Controls.StackPanel
    $Footer.Orientation = "Horizontal"
    $Footer.HorizontalAlignment = "Right"
    $Footer.Margin = [System.Windows.Thickness]::new(0, 14, 0, 0)
    [System.Windows.Controls.Grid]::SetRow($Footer, 2)
    $CancelButton = New-Object System.Windows.Controls.Button
    $CancelButton.Content = "Annulla"
    $CancelButton.Padding = [System.Windows.Thickness]::new(18, 8, 18, 8)
    $CancelButton.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    $CancelButton.Add_Click({ $Dialog.DialogResult = $false })
    [void]$Footer.Children.Add($CancelButton)
    $SaveButton = New-Object System.Windows.Controls.Button
    $SaveButton.Content = "Salva mappatura"
    $SaveButton.Padding = [System.Windows.Thickness]::new(18, 8, 18, 8)
    $SaveButton.Background = Get-Brush "#2878D0"
    $SaveButton.Foreground = Get-Brush "#FFFFFF"
    $SaveButton.BorderThickness = [System.Windows.Thickness]::new(0)
    $SaveButton.Add_Click({
        $Missing = @($Clients | Where-Object {
            $null -eq $Editors[$_].SelectedItem -or [string]$Editors[$_].SelectedItem.Tag -eq "__unassigned__"
        })
        if ($Missing.Count -gt 0) {
            [System.Windows.MessageBox]::Show("Selezionare una destinazione per tutti i clienti. Mancanti: $($Missing -join ', ')", "Mappatura incompleta", "OK", "Warning") | Out-Null
            return
        }
        $Dialog.DialogResult = $true
    })
    [void]$Footer.Children.Add($SaveButton)
    [void]$Layout.Children.Add($Footer)
    $Dialog.Content = $Layout

    if ($BuildOnly) {
        return [pscustomobject]@{ Window = $Dialog; Editors = $Editors }
    }

    if ($Dialog.ShowDialog() -ne $true) { return }
    $NewMap = @{}
    foreach ($Client in $Clients) {
        $NewMap[$Client] = [string]$Editors[$Client].SelectedItem.Tag
    }
    $script:ClientDestinationMap = $NewMap
    Reset-ImportPlan "Mappatura clienti modificata. Ripetere il dry-run autenticato."
    Update-ClientMappingButtonState
    Add-Activity "Mappatura Passbolt configurata per $($Clients.Count) clienti; il piano precedente e' stato invalidato."
}

function Reset-ImportWorkflow {
    $script:ImportCandidates = @()
    $script:ImportSecretOverrides = @{}
    $script:ImportSourceFilePasswords = @{}
    $script:ClientDestinationMap = @{}
    $ImportMetricSelected.Text = [string][char]0x2014
    $ImportSummary.Text = "Prepara i candidati dalla revisione"
    Reset-ImportPlan
    $StepImportNumber.Foreground = Get-Brush "#667683"
    $StepImportText.Foreground = Get-Brush "#667683"
    Update-ClientMappingButtonState
    Update-ImportSessionState
}

function Get-ReviewCandidateRequest($Row, [switch]$ForReveal) {
    $PasswordOverridden = if ($ForReveal) { $false } else { [bool]$Row.PasswordOverridden }
    return [pscustomobject][ordered]@{
        candidate_id = [string]$Row.CandidateId
        source_relative_path = [string]$Row.SourceRelativePath
        source_sha256 = [string]$Row.SourceHash
        client = [string]$Row.Client
        source_at_root = ([string]$Row.Client).Trim().Equals("(radice)", [StringComparison]::OrdinalIgnoreCase)
        title = [string]$Row.Title
        username = [string]$Row.Username
        uri = [string]$Row.Uri
        reviewed_client = [string]$Row.OriginalClient
        reviewed_source_at_root = [bool]$Row.OriginalSourceAtRoot
        reviewed_title = [string]$Row.OriginalTitle
        reviewed_username = [string]$Row.OriginalUsername
        reviewed_uri = [string]$Row.OriginalUri
        password_overridden = $PasswordOverridden
        source_password_required = [bool]$Row.SourcePasswordRequired
    }
}

function Get-ReviewSourceFilePasswordPayload([object[]]$Rows) {
    $Payload = New-Object System.Collections.Generic.List[object]
    $Seen = @{}
    foreach ($Row in @($Rows | Where-Object { [bool]$_.SourcePasswordRequired })) {
        $RelativePath = [string]$Row.SourceRelativePath
        if ($Seen.ContainsKey($RelativePath)) { continue }
        if (-not $script:ReviewFilePasswords.ContainsKey($RelativePath) -or -not [string]$script:ReviewFilePasswords[$RelativePath]) {
            throw "La password del file Excel $RelativePath non e' piu disponibile in memoria. Ripetere la revisione."
        }
        $Payload.Add([pscustomobject][ordered]@{
            relative_path = $RelativePath
            password = [string]$script:ReviewFilePasswords[$RelativePath]
        })
        $Seen[$RelativePath] = $true
    }
    return $Payload.ToArray()
}

function Get-ImportSourceFilePasswordPayload([object[]]$Candidates) {
    $Payload = New-Object System.Collections.Generic.List[object]
    $Seen = @{}
    foreach ($Candidate in @($Candidates | Where-Object { [bool]$_.source_password_required })) {
        $RelativePath = [string]$Candidate.source_relative_path
        if ($Seen.ContainsKey($RelativePath)) { continue }
        if (-not $script:ImportSourceFilePasswords.ContainsKey($RelativePath) -or -not [string]$script:ImportSourceFilePasswords[$RelativePath]) {
            throw "La password del file Excel $RelativePath non e' piu disponibile in memoria. Tornare alla revisione."
        }
        $Payload.Add([pscustomobject][ordered]@{
            relative_path = $RelativePath
            password = [string]$script:ImportSourceFilePasswords[$RelativePath]
        })
        $Seen[$RelativePath] = $true
    }
    return $Payload.ToArray()
}

function Update-ReviewRowState($Row) {
    $Client = ([string]$Row.Client).Trim()
    $Title = ([string]$Row.Title).Trim()
    $Username = ([string]$Row.Username).Trim()
    $Uri = ([string]$Row.Uri).Trim()
    $PasswordAvailable = [bool]$Row.SecretPresent -or [bool]$Row.PasswordOverridden
    $Ready = (
        $PasswordAvailable -and
        $Client.Length -gt 0 -and $Client.Length -le 256 -and
        $Title.Length -gt 0 -and $Title.Length -le 255 -and
        $Username.Length -le 255 -and $Uri.Length -le 2048 -and
        ($Username.Length -gt 0 -or $Uri.Length -gt 0)
    )
    $Row.Status = if ($Ready) { "ready" } else { "incomplete" }
    $Row.IsEdited = (
        $Client -cne [string]$Row.OriginalClient -or
        $Title -cne [string]$Row.OriginalTitle -or
        $Username -cne [string]$Row.OriginalUsername -or
        $Uri -cne [string]$Row.OriginalUri -or
        [bool]$Row.PasswordOverridden
    )
    if ($Ready) {
        $Row.StatusLabel = if ([bool]$Row.IsEdited) { "Pronto (modificato)" } else { "Pronto" }
    } else {
        $Row.StatusLabel = if ([bool]$Row.IsEdited) { "Da completare (modificato)" } else { "Da completare" }
    }
    if ($script:ReviewPasswordsVisible -and ([bool]$Row.PasswordOverridden -or [bool]$Row.SecretCachedFromSource)) {
        $Row.SecretDisplay = [string]$Row.SecretValue
    } elseif ($PasswordAvailable) {
        $Length = if ([bool]$Row.PasswordOverridden) { ([string]$Row.SecretValue).Length } else { [int]$Row.SecretLength }
        $Row.SecretDisplay = "******** ($Length)"
    } else {
        $Row.SecretDisplay = "Mancante"
    }
}

function Update-ReviewMetrics {
    $ReadyCount = @($script:AllReviewRows | Where-Object { $_.Status -eq "ready" }).Count
    $IncompleteCount = $script:AllReviewRows.Count - $ReadyCount
    $ReviewMetricCandidates.Text = [string]$script:AllReviewRows.Count
    $ReviewMetricReady.Text = [string]$ReadyCount
    $ReviewMetricIncomplete.Text = [string]$IncompleteCount
}

function Read-ReviewSourceSecrets([object[]]$Rows) {
    $PendingRows = @($Rows | Where-Object {
        [bool]$_.SecretPresent -and -not [bool]$_.PasswordOverridden -and -not [bool]$_.SecretCachedFromSource
    })
    if ($PendingRows.Count -lt 1) { return }
    $Requests = @($PendingRows | ForEach-Object { Get-ReviewCandidateRequest $_ -ForReveal })
    $Envelope = $null
    $ById = @{}
    $SourceFilePasswords = @()
    $SecureRequest = $null
    try {
        $SourceFilePasswords = @(Get-ReviewSourceFilePasswordPayload $PendingRows)
        $SecureRequest = [pscustomobject]@{
            candidates = $Requests
            source_file_passwords = $SourceFilePasswords
        }
        $Envelope = Invoke-SecureJsonProcess $PythonExecutable @($ImportScript, "--reveal", "--root", $script:InventoryFolder) $SecureRequest
        if (-not [bool]$Envelope.ok) { throw (Get-SecureErrorMessage $Envelope) }
        foreach ($SecretItem in @($Envelope.result.secrets)) {
            $ById[[string]$SecretItem.candidate_id] = [string]$SecretItem.password
        }
        foreach ($Row in $PendingRows) {
            if (-not $ById.ContainsKey([string]$Row.CandidateId)) {
                throw "La password richiesta non e' stata restituita dalla lettura locale."
            }
            $Row.SecretValue = [string]$ById[[string]$Row.CandidateId]
            $Row.SecretCachedFromSource = $true
        }
        $ById.Clear()
    } finally {
        $ById.Clear()
        $Requests = $null
        foreach ($Entry in $SourceFilePasswords) { $Entry.password = $null }
        if ($null -ne $SecureRequest) { $SecureRequest.source_file_passwords = $null }
        $SourceFilePasswords = @()
        $SecureRequest = $null
        if ($null -ne $Envelope -and $null -ne $Envelope.result) {
            $Envelope.result.secrets = $null
        }
        $Envelope = $null
    }
}

function Set-ReviewPasswordsVisible([bool]$Visible, [switch]$SkipPrompt) {
    if ($Visible -and -not $script:ReviewPasswordsVisible) {
        if (-not $SkipPrompt) {
            $Decision = [System.Windows.MessageBox]::Show(
                "Le password dei candidati verranno rilette dai file verificati e mostrate in chiaro sullo schermo. Rimarranno soltanto nella memoria della sessione e non saranno salvate o registrate. Continuare?",
                "Mostra password",
                [System.Windows.MessageBoxButton]::YesNo,
                [System.Windows.MessageBoxImage]::Warning
            )
            if ($Decision -ne [System.Windows.MessageBoxResult]::Yes) {
                $script:UpdatingReviewPasswordToggle = $true
                try { $ReviewPasswordToggle.IsChecked = $false } finally { $script:UpdatingReviewPasswordToggle = $false }
                return
            }
        }
        try {
            Read-ReviewSourceSecrets $script:AllReviewRows
            $script:ReviewPasswordsVisible = $true
            Add-Activity "Visualizzazione temporanea delle password attivata; nessun valore segreto e' stato registrato."
        } catch {
            $script:ReviewPasswordsVisible = $false
            foreach ($Row in $script:AllReviewRows) {
                if (-not [bool]$Row.PasswordOverridden) {
                    $Row.SecretValue = ""
                    $Row.SecretCachedFromSource = $false
                }
            }
            $script:UpdatingReviewPasswordToggle = $true
            try { $ReviewPasswordToggle.IsChecked = $false } finally { $script:UpdatingReviewPasswordToggle = $false }
            [System.Windows.MessageBox]::Show($_.Exception.Message, "Password non disponibili", "OK", "Error") | Out-Null
        }
    } elseif (-not $Visible) {
        $script:ReviewPasswordsVisible = $false
        foreach ($Row in $script:AllReviewRows) {
            if (-not [bool]$Row.PasswordOverridden) {
                $Row.SecretValue = ""
                $Row.SecretCachedFromSource = $false
            }
        }
    }

    foreach ($Row in $script:AllReviewRows) { Update-ReviewRowState $Row }
    $ReviewPasswordState.Text = if ($script:ReviewPasswordsVisible) { "PASSWORD VISIBILI" } else { "PASSWORD MASCHERATE" }
    $ReviewPasswordState.Foreground = if ($script:ReviewPasswordsVisible) { Get-Brush "#B42318" } else { Get-Brush "#16875D" }
    $ReviewPasswordToggle.Content = if ($script:ReviewPasswordsVisible) { "Nascondi password" } else { "Mostra password" }
    if ([bool]$ReviewPasswordToggle.IsChecked -ne $script:ReviewPasswordsVisible) {
        $script:UpdatingReviewPasswordToggle = $true
        try { $ReviewPasswordToggle.IsChecked = $script:ReviewPasswordsVisible } finally { $script:UpdatingReviewPasswordToggle = $false }
    }
    $ReviewCandidatesGrid.Items.Refresh()
}

function Show-ReviewCandidateEditor($Row = $null, [switch]$BuildOnly) {
    if ($null -eq $Row) {
        $Selected = @($ReviewCandidatesGrid.SelectedItems)
        if ($Selected.Count -ne 1) { return }
        $Row = $Selected[0]
    }
    if (-not $BuildOnly -and [bool]$Row.SecretPresent -and -not [bool]$Row.PasswordOverridden -and -not [bool]$Row.SecretCachedFromSource) {
        try {
            Read-ReviewSourceSecrets @($Row)
        } catch {
            [System.Windows.MessageBox]::Show($_.Exception.Message, "Password non disponibile", "OK", "Error") | Out-Null
            return
        }
    }

    $Dialog = New-Object System.Windows.Window
    $Dialog.Title = "Modifica candidato - Passbolt"
    $Dialog.Width = 670
    $Dialog.Height = 520
    $Dialog.MinWidth = 570
    $Dialog.MinHeight = 480
    $Dialog.WindowStartupLocation = "CenterOwner"
    if (-not $BuildOnly -and $Window.IsVisible) { $Dialog.Owner = $Window }
    $Dialog.Background = Get-Brush "#F4F6F8"
    $Dialog.FontFamily = "Segoe UI"

    $Layout = New-Object System.Windows.Controls.Grid
    $Layout.Margin = [System.Windows.Thickness]::new(22)
    foreach ($Height in @("Auto", "*", "Auto", "Auto")) {
        $Definition = New-Object System.Windows.Controls.RowDefinition
        $Definition.Height = if ($Height -eq "*") { [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star) } else { [System.Windows.GridLength]::Auto }
        [void]$Layout.RowDefinitions.Add($Definition)
    }

    $Header = New-Object System.Windows.Controls.StackPanel
    $Header.Margin = [System.Windows.Thickness]::new(0, 0, 0, 14)
    $HeaderTitle = New-Object System.Windows.Controls.TextBlock
    $HeaderTitle.Text = "Correggi i dati prima dell'importazione"
    $HeaderTitle.FontSize = 20
    $HeaderTitle.FontWeight = "Bold"
    $HeaderText = New-Object System.Windows.Controls.TextBlock
    $HeaderText.Text = "Le modifiche saranno usate nel dry-run e nella risorsa Passbolt. Il file sorgente non verra' modificato."
    $HeaderText.TextWrapping = "Wrap"
    $HeaderText.Foreground = Get-Brush "#66737F"
    $HeaderText.Margin = [System.Windows.Thickness]::new(0, 4, 0, 0)
    [void]$Header.Children.Add($HeaderTitle)
    [void]$Header.Children.Add($HeaderText)
    [void]$Layout.Children.Add($Header)

    $FormBorder = New-Object System.Windows.Controls.Border
    $FormBorder.Background = Get-Brush "#FFFFFF"
    $FormBorder.BorderBrush = Get-Brush "#DDE3E8"
    $FormBorder.BorderThickness = [System.Windows.Thickness]::new(1)
    $FormBorder.CornerRadius = [System.Windows.CornerRadius]::new(5)
    $FormBorder.Padding = [System.Windows.Thickness]::new(16)
    [System.Windows.Controls.Grid]::SetRow($FormBorder, 1)
    $Form = New-Object System.Windows.Controls.Grid
    $LabelColumn = New-Object System.Windows.Controls.ColumnDefinition
    $LabelColumn.Width = [System.Windows.GridLength]::new(120)
    $EditorColumn = New-Object System.Windows.Controls.ColumnDefinition
    $EditorColumn.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
    [void]$Form.ColumnDefinitions.Add($LabelColumn)
    [void]$Form.ColumnDefinitions.Add($EditorColumn)
    1..5 | ForEach-Object {
        $Definition = New-Object System.Windows.Controls.RowDefinition
        $Definition.Height = [System.Windows.GridLength]::Auto
        [void]$Form.RowDefinitions.Add($Definition)
    }

    $Editors = @{}
    $FieldSpecs = @(
        @("Cliente", "Client", [string]$Row.Client, 256),
        @("Titolo", "Title", [string]$Row.Title, 255),
        @("Username", "Username", [string]$Row.Username, 255),
        @("URL / host", "Uri", [string]$Row.Uri, 2048)
    )
    for ($Index = 0; $Index -lt $FieldSpecs.Count; $Index++) {
        $Spec = $FieldSpecs[$Index]
        $Label = New-Object System.Windows.Controls.TextBlock
        $Label.Text = [string]$Spec[0]
        $Label.VerticalAlignment = "Center"
        $Label.FontWeight = "SemiBold"
        $Label.Margin = [System.Windows.Thickness]::new(0, 0, 10, 10)
        [System.Windows.Controls.Grid]::SetRow($Label, $Index)
        [void]$Form.Children.Add($Label)
        $Editor = New-Object System.Windows.Controls.TextBox
        $Editor.Text = [string]$Spec[2]
        $Editor.MaxLength = [int]$Spec[3]
        $Editor.Margin = [System.Windows.Thickness]::new(0, 0, 0, 10)
        [System.Windows.Controls.Grid]::SetRow($Editor, $Index)
        [System.Windows.Controls.Grid]::SetColumn($Editor, 1)
        [void]$Form.Children.Add($Editor)
        $Editors[[string]$Spec[1]] = $Editor
    }

    $PasswordLabel = New-Object System.Windows.Controls.TextBlock
    $PasswordLabel.Text = "Password"
    $PasswordLabel.VerticalAlignment = "Top"
    $PasswordLabel.FontWeight = "SemiBold"
    $PasswordLabel.Margin = [System.Windows.Thickness]::new(0, 8, 10, 0)
    [System.Windows.Controls.Grid]::SetRow($PasswordLabel, 4)
    [void]$Form.Children.Add($PasswordLabel)
    $PasswordPanel = New-Object System.Windows.Controls.Grid
    $PasswordEditorRow = New-Object System.Windows.Controls.RowDefinition
    $PasswordEditorRow.Height = [System.Windows.GridLength]::Auto
    $PasswordToggleRow = New-Object System.Windows.Controls.RowDefinition
    $PasswordToggleRow.Height = [System.Windows.GridLength]::Auto
    [void]$PasswordPanel.RowDefinitions.Add($PasswordEditorRow)
    [void]$PasswordPanel.RowDefinitions.Add($PasswordToggleRow)
    $PasswordBox = New-Object System.Windows.Controls.PasswordBox
    $PasswordBox.MaxLength = 65536
    $PasswordBox.Password = [string]$Row.SecretValue
    $PasswordText = New-Object System.Windows.Controls.TextBox
    $PasswordText.MaxLength = 65536
    $PasswordText.Text = [string]$Row.SecretValue
    $PasswordText.Visibility = "Collapsed"
    $ShowPassword = New-Object System.Windows.Controls.CheckBox
    $ShowPassword.Content = "Mostra password durante la modifica"
    $ShowPassword.Margin = [System.Windows.Thickness]::new(0, 7, 0, 0)
    [System.Windows.Controls.Grid]::SetRow($ShowPassword, 1)
    $ShowPassword.Add_Checked({
        $PasswordText.Text = $PasswordBox.Password
        $PasswordBox.Visibility = "Collapsed"
        $PasswordText.Visibility = "Visible"
    })
    $ShowPassword.Add_Unchecked({
        $PasswordBox.Password = $PasswordText.Text
        $PasswordText.Visibility = "Collapsed"
        $PasswordBox.Visibility = "Visible"
    })
    [void]$PasswordPanel.Children.Add($PasswordBox)
    [void]$PasswordPanel.Children.Add($PasswordText)
    [void]$PasswordPanel.Children.Add($ShowPassword)
    [System.Windows.Controls.Grid]::SetRow($PasswordPanel, 4)
    [System.Windows.Controls.Grid]::SetColumn($PasswordPanel, 1)
    [void]$Form.Children.Add($PasswordPanel)
    $Editors["Password"] = $PasswordBox
    $FormBorder.Child = $Form
    [void]$Layout.Children.Add($FormBorder)

    $Notice = New-Object System.Windows.Controls.TextBlock
    $Notice.Text = "La password resta soltanto nella memoria della sessione e non viene scritta nel registro."
    $Notice.Foreground = Get-Brush "#66737F"
    $Notice.FontSize = 11
    $Notice.Margin = [System.Windows.Thickness]::new(0, 10, 0, 0)
    [System.Windows.Controls.Grid]::SetRow($Notice, 2)
    [void]$Layout.Children.Add($Notice)

    $Footer = New-Object System.Windows.Controls.StackPanel
    $Footer.Orientation = "Horizontal"
    $Footer.HorizontalAlignment = "Right"
    $Footer.Margin = [System.Windows.Thickness]::new(0, 14, 0, 0)
    [System.Windows.Controls.Grid]::SetRow($Footer, 3)
    $CancelButton = New-Object System.Windows.Controls.Button
    $CancelButton.Content = "Annulla"
    $CancelButton.Padding = [System.Windows.Thickness]::new(18, 8, 18, 8)
    $CancelButton.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    $CancelButton.Add_Click({ $Dialog.DialogResult = $false })
    $SaveButton = New-Object System.Windows.Controls.Button
    $SaveButton.Content = "Salva modifiche"
    $SaveButton.Padding = [System.Windows.Thickness]::new(18, 8, 18, 8)
    $SaveButton.Background = Get-Brush "#2878D0"
    $SaveButton.Foreground = Get-Brush "#FFFFFF"
    $SaveButton.BorderThickness = [System.Windows.Thickness]::new(0)
    $SaveButton.Add_Click({
        $Password = if ([bool]$ShowPassword.IsChecked) { [string]$PasswordText.Text } else { [string]$PasswordBox.Password }
        $Client = $Editors.Client.Text.Trim()
        $Title = $Editors.Title.Text.Trim()
        $Username = $Editors.Username.Text.Trim()
        $Uri = $Editors.Uri.Text.Trim()
        if (-not $Client -or -not $Title -or -not $Password) {
            [System.Windows.MessageBox]::Show("Cliente, titolo e password sono obbligatori.", "Dati incompleti", "OK", "Warning") | Out-Null
            return
        }
        if (-not $Username -and -not $Uri) {
            [System.Windows.MessageBox]::Show("Inserire almeno uno fra username e URL/host.", "Dati incompleti", "OK", "Warning") | Out-Null
            return
        }
        $Dialog.Tag = [pscustomobject]@{ Client = $Client; Title = $Title; Username = $Username; Uri = $Uri; Password = $Password }
        $Dialog.DialogResult = $true
    })
    [void]$Footer.Children.Add($CancelButton)
    [void]$Footer.Children.Add($SaveButton)
    [void]$Layout.Children.Add($Footer)
    $Dialog.Content = $Layout

    if ($BuildOnly) {
        return [pscustomobject]@{ Window = $Dialog; Editors = $Editors; PasswordText = $PasswordText; ShowPassword = $ShowPassword }
    }

    $OriginalPassword = [string]$Row.SecretValue
    if ($Dialog.ShowDialog() -ne $true) {
        if (-not $script:ReviewPasswordsVisible -and -not [bool]$Row.PasswordOverridden) {
            $Row.SecretValue = ""
            $Row.SecretCachedFromSource = $false
            Update-ReviewRowState $Row
        }
        return
    }
    $Result = $Dialog.Tag
    $Row.Client = [string]$Result.Client
    $Row.Title = [string]$Result.Title
    $Row.Username = [string]$Result.Username
    $Row.Uri = [string]$Result.Uri
    $Row.PasswordOverridden = (-not [bool]$Row.SecretPresent) -or -not [string]::Equals([string]$Result.Password, $OriginalPassword, [StringComparison]::Ordinal)
    $Row.SecretValue = [string]$Result.Password
    $Row.SecretCachedFromSource = -not [bool]$Row.PasswordOverridden
    if (-not $script:ReviewPasswordsVisible -and -not [bool]$Row.PasswordOverridden) {
        $Row.SecretValue = ""
        $Row.SecretCachedFromSource = $false
    }
    Update-ReviewRowState $Row
    Update-ReviewMetrics
    Reset-ImportWorkflow
    Apply-ReviewFilters
    Add-Activity "Candidato $($Row.CandidateId) modificato in memoria; nessun valore segreto e' stato registrato."
}

function Update-ImportSelectionState {
    $Selected = @($ReviewCandidatesGrid.SelectedItems)
    $ReadyCount = @($Selected | Where-Object { $_.Status -eq "ready" }).Count
    $AllReady = ($Selected.Count -gt 0 -and $ReadyCount -eq $Selected.Count)
    $PrepareImportButton.Content = "Prepara importazione ($($Selected.Count))"
    $PrepareImportButton.IsEnabled = ($AllReady -and $Selected.Count -le 25)
    $EditReviewCandidateButton.IsEnabled = ($Selected.Count -eq 1)
    if ($Selected.Count -gt 25) {
        $PrepareImportButton.Content = "Massimo 25 candidati"
    } elseif ($Selected.Count -gt 0 -and -not $AllReady) {
        $PrepareImportButton.Content = "Seleziona solo candidati pronti"
    }
}

function Update-ExecuteImportState {
    $SessionReady = (
        (Test-ImportSessionActive) -and
        $script:ImportSessionRoot -eq $script:InventoryFolder -and
        [string]$script:ImportPlan.session_id -eq $script:ImportSessionId
    )
    $CanExecute = (
        $null -ne $script:ImportPlan -and
        $script:ConnectionVerified -and
        $SessionReady -and
        [bool]$script:ImportPlan.can_import -and
        [int]$script:ImportPlan.create_count -gt 0 -and
        $ImportConfirmation.Text.Trim() -eq "IMPORTA $([int]$script:ImportPlan.create_count)"
    )
    $ExecuteImportButton.IsEnabled = $CanExecute
}

function Open-ImportPreparation {
    $Selected = @($ReviewCandidatesGrid.SelectedItems)
    if ($Selected.Count -lt 1) { return }
    if ($Selected.Count -gt 25) {
        [System.Windows.MessageBox]::Show("Selezionare al massimo 25 candidati pronti per ogni importazione.", "Troppi candidati", "OK", "Warning") | Out-Null
        return
    }
    if (@($Selected | Where-Object { $_.Status -ne "ready" }).Count -gt 0) {
        [System.Windows.MessageBox]::Show("La selezione contiene candidati da completare. Selezionare soltanto righe con stato Pronto.", "Selezione non importabile", "OK", "Warning") | Out-Null
        return
    }

    $Candidates = New-Object System.Collections.Generic.List[object]
    $script:ImportSecretOverrides = @{}
    $script:ImportSourceFilePasswords = @{}
    foreach ($Row in $Selected) {
        $Candidates.Add((Get-ReviewCandidateRequest $Row))
        if ([bool]$Row.SourcePasswordRequired) {
            $RelativePath = [string]$Row.SourceRelativePath
            if (-not $script:ReviewFilePasswords.ContainsKey($RelativePath) -or -not [string]$script:ReviewFilePasswords[$RelativePath]) {
                [System.Windows.MessageBox]::Show("La password del file Excel $RelativePath non e' piu disponibile in memoria. Ripetere la revisione.", "Password Excel non disponibile", "OK", "Error") | Out-Null
                $script:ImportSecretOverrides = @{}
                $script:ImportSourceFilePasswords = @{}
                return
            }
            $script:ImportSourceFilePasswords[$RelativePath] = [string]$script:ReviewFilePasswords[$RelativePath]
        }
        if ([bool]$Row.PasswordOverridden) {
            if (-not [string]$Row.SecretValue) {
                [System.Windows.MessageBox]::Show("La password modificata di un candidato non e' piu disponibile in memoria. Modificare nuovamente il candidato.", "Password non disponibile", "OK", "Error") | Out-Null
                $script:ImportSecretOverrides = @{}
                $script:ImportSourceFilePasswords = @{}
                return
            }
            $script:ImportSecretOverrides[[string]$Row.CandidateId] = [string]$Row.SecretValue
        }
    }
    $script:ImportCandidates = $Candidates.ToArray()
    $script:ClientDestinationMap = @{}
    $ImportMetricSelected.Text = [string]$script:ImportCandidates.Count
    $ImportSummary.Text = "$($script:ImportCandidates.Count) candidati pronti selezionati dalla revisione"
    Update-ClientMappingButtonState
    $PreparationStatus = if (Test-ImportSessionActive) {
        "Candidati preparati. La sessione e' attiva: configurare la destinazione ed eseguire il dry-run."
    } else {
        "Candidati preparati. Selezionare la chiave privata, inserire passphrase e MFA, quindi avviare la sessione."
    }
    Reset-ImportPlan $PreparationStatus
    $StepImportNumber.Foreground = Get-Brush "#62A8EA"
    $StepImportText.Foreground = Get-Brush "#D6DEE5"
    Add-Activity "Preparazione importazione: $($script:ImportCandidates.Count) candidati, nessun segreto registrato."
    Update-ImportSessionState
    Show-Page "Import"
}

function Invoke-ImportReadiness {
    if (-not $script:ConnectionVerified -or -not $script:VerifiedUrl -or -not $script:VerifiedFingerprint) {
        [System.Windows.MessageBox]::Show("La connessione Passbolt non e' verificata. Tornare alla configurazione.", "Connessione non verificata", "OK", "Warning") | Out-Null
        return
    }
    if ($script:ImportCandidates.Count -lt 1) {
        [System.Windows.MessageBox]::Show("Tornare alla revisione e selezionare almeno un candidato pronto.", "Nessun candidato", "OK", "Warning") | Out-Null
        return
    }
    if (-not (Test-ImportSessionActive) -or $script:ImportSessionRoot -ne $script:InventoryFolder) {
        [System.Windows.MessageBox]::Show("Avviare prima la sessione sicura con chiave privata, passphrase e MFA.", "Sessione non attiva", "OK", "Warning") | Out-Null
        return
    }

    Reset-ImportPlan "Controllo integrita' e dry-run nella sessione autenticata in corso..."
    $DryRunButton.IsEnabled = $false
    $ReadinessRequest = $null
    $ReadinessSourceFilePasswords = @()
    $Envelope = $null
    $CloseSessionForError = $false
    $RequestedResourceFormat = [string]$ResourceFormat.SelectedItem.Tag
    if ($RequestedResourceFormat -notin @("auto", "v4", "v5")) { $RequestedResourceFormat = "auto" }
    $RequestedFolderFormat = [string]$FolderFormat.SelectedItem.Tag
    if ($RequestedFolderFormat -notin @("auto", "v4", "v5")) { $RequestedFolderFormat = "auto" }
    $RequestedDestinationMode = [string]$DestinationMode.SelectedItem.Tag
    if ($RequestedDestinationMode -notin @("client_folders", "client_mapping", "direct_folder", "root")) { $RequestedDestinationMode = "client_folders" }
    $RequestedDestinationFolderId = if ($RequestedDestinationMode -eq "client_mapping") { "" } else { Get-SelectedDestinationFolderId }
    $RequestedClientDestinationMapping = if ($RequestedDestinationMode -eq "client_mapping") { @(Get-ClientDestinationMappingPayload) } else { @() }
    Add-Activity "Avvio dry-run nella sessione GPGAuth attiva (risorse $RequestedResourceFormat, cartelle $RequestedFolderFormat)."
    Update-Ui
    try {
        $ReadinessSourceFilePasswords = @(Get-ImportSourceFilePasswordPayload $script:ImportCandidates)
        $ReadinessRequest = [pscustomobject][ordered]@{
            command = "session-readiness"
            session_id = $script:ImportSessionId
            resource_format = $RequestedResourceFormat
            destination_mode = $RequestedDestinationMode
            folder_format = $RequestedFolderFormat
            destination_folder_id = $RequestedDestinationFolderId
            client_destination_mapping = $RequestedClientDestinationMapping
            candidates = $script:ImportCandidates
            source_file_passwords = $ReadinessSourceFilePasswords
        }
        $Envelope = Invoke-ImportSessionJson $ReadinessRequest
        if (-not [bool]$Envelope.ok) {
            $CloseSessionForError = Test-TerminalImportSessionError $Envelope
            throw (Get-SecureErrorMessage $Envelope)
        }
        $Result = $Envelope.result
        $script:ImportPlan = $Result
        $script:ImportPlanKeyPath = $script:ImportSessionKeyPath
        Update-DestinationFolderOptions $Result.available_folders ([string]$Result.destination_folder_id)

        $PlanRows = New-Object System.Collections.Generic.List[object]
        foreach ($Candidate in @($Result.candidates)) {
            if ($Candidate.action -eq "duplicate" -and $Candidate.duplicate_kind -eq "batch") {
                $ActionLabel = "Duplicato nel lotto"
            } elseif ($Candidate.action -eq "duplicate") {
                $ActionLabel = "Gia' nella destinazione"
            } elseif ($Candidate.action -eq "blocked") {
                $ActionLabel = "Presente altrove - bloccato"
            } else {
                $ActionLabel = "Da creare"
            }
            if ($Candidate.folder_action -eq "root") {
                $DestinationLabel = "Radice Passbolt"
            } elseif ($Candidate.folder_action -eq "reuse") {
                $DestinationLabel = "$($Candidate.folder_path) (esistente)"
            } elseif ($Candidate.folder_action -eq "missing") {
                $DestinationLabel = "Selezionare una cartella"
            } else {
                $DestinationLabel = "$($Candidate.folder_path) (nuova)"
            }
            if ([bool]$Candidate.shared) {
                $DestinationLabel += " [condivisa con $([int]$Candidate.share_recipient_count) destinatari]"
            }
            $PlanRows.Add([pscustomobject]@{
                CandidateId = [string]$Candidate.candidate_id
                Action = [string]$Candidate.action
                ActionLabel = $ActionLabel
                Destination = $DestinationLabel
                Title = [string]$Candidate.title
                Username = [string]$Candidate.username
                Uri = [string]$Candidate.uri
            })
        }
        $ImportPlanGrid.ItemsSource = $PlanRows.ToArray()
        $ImportMetricSelected.Text = [string]$script:ImportCandidates.Count
        $ImportMetricCreate.Text = [string]$Result.create_count
        $ImportMetricDuplicates.Text = [string]$Result.duplicate_count
        $ImportMetricExisting.Text = [string]$Result.create_folder_count
        $DisplayName = ("$($Result.user.first_name) $($Result.user.last_name)").Trim()
        if (-not $DisplayName) { $DisplayName = [string]$Result.user.username }
        $SelectedFolderLabel = if ($null -ne $DestinationFolder.SelectedItem) { [string]$DestinationFolder.SelectedItem.Content } else { "Radice personale Passbolt" }
        if ([string]$Result.destination_mode -eq "root") {
            $FolderIdentity = "radice"
        } elseif ([string]$Result.destination_mode -eq "direct_folder") {
            $FolderIdentity = "diretta: $SelectedFolderLabel"
        } elseif ([string]$Result.destination_mode -eq "client_mapping") {
            $FolderIdentity = "mappatura: $(@($Result.client_destination_mapping).Count)/$(@($Result.required_clients).Count) clienti"
        } elseif (-not [string]$Result.folder_format_selected) {
            $FolderIdentity = "nessuna nuova cartella"
        } else {
            $FolderIdentity = "contenitore: $SelectedFolderLabel; cartelle $($Result.folder_format_selected)"
        }
        $ImportIdentity.Text = "Utente verificato: $DisplayName <$($Result.user.username)> | chiave $($Result.user_key_fingerprint) | $($Result.authentication) | risorse $($Result.resource_format_selected) | $FolderIdentity | tipo $($Result.resource_type.slug)"

        if ([bool]$Result.can_import -and [int]$Result.create_count -gt 0) {
            $ExpectedPhrase = "IMPORTA $([int]$Result.create_count)"
            $SharedFolderSummary = if ([int]$Result.create_shared_folder_count -gt 0) {
                " Cartelle condivise da creare con permessi ereditati: $([int]$Result.create_shared_folder_count)."
            } else { "" }
            $ReconciledFolderSummary = if ([int]$Result.reconcile_shared_folder_count -gt 0) {
                " Cartelle personali vuote da riconciliare con i permessi del contenitore: $([int]$Result.reconcile_shared_folder_count)."
            } else { "" }
            $SharingSummary = if ([int]$Result.shared_create_count -gt 0) {
                " Risorse condivise: $([int]$Result.shared_create_count); copie cifrate complessive: $([int]$Result.encrypted_secret_copy_count)."
            } else { "" }
            $ImportPlanStatus.Text = "Dry-run completato. Nessuna modifica eseguita; cartelle nuove: $($Result.create_folder_count), da riconciliare: $($Result.reconcile_shared_folder_count), cartelle riutilizzate: $($Result.reuse_folder_count).$SharedFolderSummary$ReconciledFolderSummary$SharingSummary Le cartelle Passbolt sono caricate: se cambi la destinazione, ripeti il dry-run."
            $ConfirmationHint.Text = "Sessione sicura attiva. Digita: $ExpectedPhrase"
            $ImportConfirmation.IsEnabled = $true
            Add-Activity "Dry-run completato: $($Result.create_count) risorse e $($Result.create_folder_count) cartelle da creare, $($Result.reconcile_shared_folder_count) cartelle da riconciliare, incluse $($Result.create_shared_folder_count) nuove condivise; $($Result.duplicate_count) duplicati nella destinazione."
        } elseif ([bool]$Result.can_import) {
            $ImportPlanStatus.Text = "Dry-run completato: tutti i candidati selezionati risultano gia' presenti."
            $ConfirmationHint.Text = "Nessuna nuova risorsa da creare."
            Add-Activity "Dry-run completato: nessuna nuova risorsa; $($Result.duplicate_count) duplicati esatti."
        } else {
            $ImportPlanStatus.Text = [string]$Result.unavailable_reason
            $ConfirmationHint.Text = "Scrittura bloccata dalle capacita' dichiarate dal server."
            Add-Activity "Dry-run completato; scrittura non disponibile per le capacita' dell'istanza."
        }
    } catch {
        $FailureMessage = [string]$_.Exception.Message
        if ($CloseSessionForError -or -not (Test-ImportSessionActive)) {
            Stop-ImportSession "" $false
        }
        Reset-ImportPlan "Dry-run non riuscito. Nessuna modifica e' stata eseguita."
        Add-Activity "Dry-run non riuscito: $FailureMessage"
        [System.Windows.MessageBox]::Show($FailureMessage, "Dry-run non riuscito", "OK", "Error") | Out-Null
    } finally {
        foreach ($Entry in $ReadinessSourceFilePasswords) { $Entry.password = $null }
        if ($null -ne $ReadinessRequest) { $ReadinessRequest.source_file_passwords = $null }
        $ReadinessSourceFilePasswords = @()
        $ReadinessRequest = $null
        Update-ImportSessionState
    }
}

function Invoke-ConfirmedImport {
    Update-ExecuteImportState
    if (-not $ExecuteImportButton.IsEnabled) { return }
    if (-not (Test-ImportSessionActive)) {
        [System.Windows.MessageBox]::Show("La sessione sicura non e' piu attiva. Avviarne una nuova e ripetere il dry-run.", "Sessione scaduta", "OK", "Warning") | Out-Null
        return
    }
    $CreateCount = [int]$script:ImportPlan.create_count
    $DuplicateCount = [int]$script:ImportPlan.duplicate_count
    $CreateFolderCount = [int]$script:ImportPlan.create_folder_count
    $CreateSharedFolderCount = [int]$script:ImportPlan.create_shared_folder_count
    $ReconcileSharedFolderCount = [int]$script:ImportPlan.reconcile_shared_folder_count
    $ReuseFolderCount = [int]$script:ImportPlan.reuse_folder_count
    $SharedCreateCount = [int]$script:ImportPlan.shared_create_count
    $EncryptedSecretCopyCount = [int]$script:ImportPlan.encrypted_secret_copy_count
    $SharingConfirmation = if ($SharedCreateCount -gt 0) {
        " Di queste, $SharedCreateCount risorse erediteranno i permessi delle cartelle condivise; saranno prodotte $EncryptedSecretCopyCount copie cifrate complessive dei segreti. Ogni condivisione verra' prima simulata da Passbolt."
    } else { "" }
    $FolderSharingConfirmation = if ($CreateSharedFolderCount -gt 0) {
        " $CreateSharedFolderCount nuove cartelle saranno create nel contenitore condiviso e riceveranno la sua maschera completa di permessi prima di creare le relative risorse."
    } else { "" }
    $FolderReconciliationConfirmation = if ($ReconcileSharedFolderCount -gt 0) {
        " $ReconcileSharedFolderCount cartelle personali gia' esistenti, verificate come vuote e di proprieta' dell'utente autenticato, riceveranno la maschera di permessi del contenitore prima della creazione delle risorse."
    } else { "" }
    $Decision = [System.Windows.MessageBox]::Show(
        "Passbolt creera' $CreateFolderCount cartelle e $CreateCount risorse, riconciliera' $ReconcileSharedFolderCount cartelle personali, riutilizzera' $ReuseFolderCount cartelle e saltera' $DuplicateCount duplicati nella destinazione.$FolderSharingConfirmation$FolderReconciliationConfirmation$SharingConfirmation Le operazioni sono sequenziali: in caso di interruzione verra' mostrato quante sono riuscite. Continuare?",
        "Conferma scrittura su Passbolt",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning
    )
    if ($Decision -ne [System.Windows.MessageBoxResult]::Yes) { return }

    $CreateCandidateIds = @($script:ImportPlan.candidates | Where-Object { $_.action -eq "create" } | ForEach-Object { [string]$_.candidate_id })
    $SecretOverrides = New-Object System.Collections.Generic.List[object]
    foreach ($CandidateId in $CreateCandidateIds) {
        $Candidate = @($script:ImportCandidates | Where-Object { [string]$_.candidate_id -eq $CandidateId }) | Select-Object -First 1
        if ($null -ne $Candidate -and [bool]$Candidate.password_overridden) {
            if (-not $script:ImportSecretOverrides.ContainsKey($CandidateId) -or -not [string]$script:ImportSecretOverrides[$CandidateId]) {
                [System.Windows.MessageBox]::Show("Una password modificata non e' piu disponibile in memoria. Tornare alla revisione e modificarla nuovamente.", "Password non disponibile", "OK", "Error") | Out-Null
                return
            }
            $SecretOverrides.Add([pscustomobject][ordered]@{
                candidate_id = $CandidateId
                password = [string]$script:ImportSecretOverrides[$CandidateId]
            })
        }
    }
    $CreateCandidates = @($script:ImportCandidates | Where-Object { [string]$_.candidate_id -in $CreateCandidateIds })
    $WriteSourceFilePasswords = @()
    try {
        $WriteSourceFilePasswords = @(Get-ImportSourceFilePasswordPayload $CreateCandidates)
    } catch {
        foreach ($Entry in $SecretOverrides) { $Entry.password = $null }
        $SecretOverrides.Clear()
        [System.Windows.MessageBox]::Show($_.Exception.Message, "Password Excel non disponibile", "OK", "Error") | Out-Null
        return
    }
    $ExecuteImportButton.IsEnabled = $false
    $DryRunButton.IsEnabled = $false
    $ExecuteRequest = [pscustomobject][ordered]@{
        command = "session-import"
        session_id = $script:ImportSessionId
        resource_format = [string]$script:ImportPlan.resource_format_requested
        destination_mode = [string]$script:ImportPlan.destination_mode
        folder_format = [string]$script:ImportPlan.folder_format_requested
        destination_folder_id = [string]$script:ImportPlan.destination_folder_id
        client_destination_mapping = @($script:ImportPlan.client_destination_mapping)
        candidates = $script:ImportCandidates
        create_candidate_ids = $CreateCandidateIds
        secret_overrides = $SecretOverrides.ToArray()
        source_file_passwords = $WriteSourceFilePasswords
        plan_digest = [string]$script:ImportPlan.plan_digest
        confirmation = "IMPORTA $CreateCount"
    }
    Add-Activity "Avvio importazione confermata di $CreateCount risorse."
    Update-Ui
    $Envelope = $null
    $CloseSessionForError = $false
    try {
        $Envelope = Invoke-ImportSessionJson $ExecuteRequest
        if (-not [bool]$Envelope.ok) {
            $CloseSessionForError = Test-TerminalImportSessionError $Envelope
            $CreatedBeforeFailure = 0
            if ($null -ne $Envelope.error.details -and $null -ne $Envelope.error.details.created) {
                $CreatedBeforeFailure = @($Envelope.error.details.created).Count
            }
            $CreatedFoldersBeforeFailure = 0
            if ($null -ne $Envelope.error.details -and $null -ne $Envelope.error.details.created_folders) {
                $CreatedFoldersBeforeFailure = @($Envelope.error.details.created_folders).Count
            }
            $Message = Get-SecureErrorMessage $Envelope
            if ($null -ne $Envelope.error.details -and -not [string]::IsNullOrWhiteSpace([string]$Envelope.error.details.reconciliation_batch_id)) {
                $Message += "`n`nRegistro locale del lotto: $([string]$Envelope.error.details.reconciliation_batch_id). Lo stato richiede verifica; la ripresa guidata sara' aggiunta nel prossimo blocco della roadmap. Prima di riprovare, eseguire un nuovo dry-run."
            }
            if ($CreatedBeforeFailure -gt 0 -or $CreatedFoldersBeforeFailure -gt 0) {
                $Message += "`n`nAttenzione: $CreatedFoldersBeforeFailure cartelle e $CreatedBeforeFailure risorse risultano create prima dell'errore. Ripetere il dry-run per riconciliare lo stato; non verranno eliminate automaticamente."
            }
            if ($null -ne $Envelope.error.details -and [bool]$Envelope.error.details.folder_reconciliation_failed) {
                $Message += "`n`nLa cartella personale $($Envelope.error.details.existing_personal_folder_id) non e' stata riconciliata con i permessi del contenitore. Nessuna risorsa del cliente e' stata inserita al suo interno. Ripetere il dry-run per verificare lo stato corrente."
            } elseif ($null -ne $Envelope.error.details -and [bool]$Envelope.error.details.folder_sharing_failed) {
                $Message += "`n`nLa cartella $($Envelope.error.details.created_unshared_folder_id) e' stata creata ma i permessi ereditati non sono stati applicati. Al momento resta personale; nessuna risorsa del cliente e' stata inserita al suo interno. Ripetere il dry-run per riconciliare lo stato."
            } elseif ($null -ne $Envelope.error.details -and [bool]$Envelope.error.details.sharing_failed) {
                $Message += "`n`nLa risorsa $($Envelope.error.details.created_unshared_resource_id) e' stata creata ma la condivisione non e' stata applicata. Al momento resta personale e deve essere riconciliata con un nuovo dry-run prima di continuare."
            }
            throw $Message
        }
        $Result = $Envelope.result
        $script:ImportCompleted = $true
        $script:ImportPlan = $null
        foreach ($CandidateId in $CreateCandidateIds) {
            if ($script:ImportSecretOverrides.ContainsKey($CandidateId)) {
                $script:ImportSecretOverrides.Remove($CandidateId)
            }
            foreach ($ReviewRow in @($script:AllReviewRows | Where-Object { [string]$_.CandidateId -eq $CandidateId })) {
                $ReviewRow.SecretValue = ""
                $ReviewRow.SecretCachedFromSource = $false
                $ReviewRow.PasswordOverridden = $false
                Update-ReviewRowState $ReviewRow
            }
        }
        Update-ReviewMetrics
        $ImportConfirmation.Text = ""
        $ImportConfirmation.IsEnabled = $false
        $ConfirmationHint.Text = "Importazione completata. La sessione resta attiva per il prossimo lotto."
        $ImportPlanStatus.Text = "Importazione completata: $($Result.created_folder_count) cartelle create, incluse $($Result.shared_created_folder_count) condivise, $($Result.reconciled_shared_folder_count) cartelle riconciliate e $($Result.created_count) risorse create, incluse $($Result.shared_created_count) condivise; $($Result.skipped_duplicate_count) duplicati saltati."
        foreach ($Row in @($ImportPlanGrid.ItemsSource)) {
            if ($Row.Action -eq "create") { $Row.ActionLabel = "Creata" }
        }
        $ImportPlanGrid.Items.Refresh()
        Add-Activity "Importazione completata: $($Result.created_folder_count) cartelle create, incluse $($Result.shared_created_folder_count) condivise, $($Result.reconciled_shared_folder_count) cartelle riconciliate e $($Result.created_count) risorse create, incluse $($Result.shared_created_count) condivise; $($Result.skipped_duplicate_count) duplicati saltati."
        if (-not [string]::IsNullOrWhiteSpace([string]$Result.reconciliation_batch_id)) {
            Add-Activity "Registro locale del lotto $([string]$Result.reconciliation_batch_id) completato."
        }
        [System.Windows.MessageBox]::Show("Importazione completata correttamente.`n`nCartelle create: $($Result.created_folder_count)`nCartelle condivise create: $($Result.shared_created_folder_count)`nCartelle personali riconciliate: $($Result.reconciled_shared_folder_count)`nCartelle riutilizzate: $($Result.reused_folder_count)`nRisorse create: $($Result.created_count)`nRisorse condivise: $($Result.shared_created_count)`nCopie cifrate complessive: $($Result.encrypted_secret_copy_count)`nDuplicati saltati: $($Result.skipped_duplicate_count)", "Importazione completata", "OK", "Information") | Out-Null
    } catch {
        $FailureMessage = [string]$_.Exception.Message
        if ($CloseSessionForError -or -not (Test-ImportSessionActive)) {
            Stop-ImportSession "" $false
        }
        Reset-ImportPlan "Importazione interrotta. Ripetere il dry-run per riconciliare lo stato del server."
        Add-Activity "Importazione non completata: $FailureMessage"
        [System.Windows.MessageBox]::Show($FailureMessage, "Importazione non completata - v0.12.5", "OK", "Error") | Out-Null
    } finally {
        foreach ($Entry in $SecretOverrides) { $Entry.password = $null }
        foreach ($Entry in $WriteSourceFilePasswords) { $Entry.password = $null }
        if ($null -ne $ExecuteRequest) {
            $ExecuteRequest.secret_overrides = $null
            $ExecuteRequest.source_file_passwords = $null
        }
        $WriteSourceFilePasswords = @()
        $SecretOverrides = $null
        $ExecuteRequest = $null
        Update-ImportSessionState
    }
}

function Test-SelectedFolder {
    $Folder = $ClientFolder.Text.Trim()
    return [bool]($Folder -and (Test-Path -LiteralPath $Folder -PathType Container))
}

function Update-ConfigurationState {
    $FolderIsValid = Test-SelectedFolder
    if ($FolderIsValid) {
        $FolderDot.Fill = Get-Brush "#16875D"
        $FolderStatus.Text = "Cartella valida e accessibile"
        $FolderStatus.Foreground = Get-Brush "#16875D"
    } elseif ($ClientFolder.Text.Trim()) {
        $FolderDot.Fill = Get-Brush "#C43D4B"
        $FolderStatus.Text = "Cartella non trovata o non accessibile"
        $FolderStatus.Foreground = Get-Brush "#C43D4B"
    } else {
        $FolderDot.Fill = Get-Brush "#98A5B1"
        $FolderStatus.Text = "Nessuna cartella selezionata"
        $FolderStatus.Foreground = Get-Brush "#66737F"
    }

    $CanContinue = $script:ConnectionVerified -and $FolderIsValid
    $ContinueButton.IsEnabled = $CanContinue
    if ($CanContinue) {
        $StepInventoryNumber.Foreground = Get-Brush "#62A8EA"
        $StepInventoryText.Foreground = Get-Brush "#D6DEE5"
    } elseif ($script:CurrentPage -ne "Inventory") {
        $StepInventoryNumber.Foreground = Get-Brush "#667683"
        $StepInventoryText.Foreground = Get-Brush "#8795A1"
    }
}

function Show-Page([ValidateSet("Configuration", "Inventory", "Review", "Import")][string]$Page) {
    if ($Page -ne "Review" -and $script:ReviewPasswordsVisible) {
        Set-ReviewPasswordsVisible $false
    }
    $script:CurrentPage = $Page
    $ConfigurationPage.Visibility = "Collapsed"
    $InventoryPage.Visibility = "Collapsed"
    $ReviewPage.Visibility = "Collapsed"
    $ImportPage.Visibility = "Collapsed"
    foreach ($Step in @($StepConfiguration, $StepInventory, $StepReview, $StepImport)) {
        $Step.Background = Get-Brush "#18212A"
    }
    $StepConfigurationText.FontWeight = "Normal"
    $StepInventoryText.FontWeight = "Normal"
    $StepReviewText.FontWeight = "Normal"
    $StepImportText.FontWeight = "Normal"

    if ($Page -eq "Configuration") {
        $ConfigurationPage.Visibility = "Visible"
        $StepConfiguration.Background = Get-Brush "#263746"
        $StepConfigurationNumber.Foreground = Get-Brush "#62A8EA"
        $StepConfigurationText.Foreground = Get-Brush "#FFFFFF"
        $StepConfigurationText.FontWeight = "SemiBold"
        $SafeModeText.Text = "Configurazione e inventario non aprono il contenuto dei documenti."
    } elseif ($Page -eq "Inventory") {
        $InventoryPage.Visibility = "Visible"
        $StepConfigurationNumber.Foreground = Get-Brush "#AEB8C2"
        $StepConfigurationText.Foreground = Get-Brush "#D6DEE5"
        $StepInventory.Background = Get-Brush "#263746"
        $StepInventoryNumber.Foreground = Get-Brush "#62A8EA"
        $StepInventoryText.Foreground = Get-Brush "#FFFFFF"
        $StepInventoryText.FontWeight = "SemiBold"
        $SafeModeText.Text = "L'inventario usa soltanto metadati. Seleziona i file da autorizzare per la revisione."
    } elseif ($Page -eq "Review") {
        $ReviewPage.Visibility = "Visible"
        $StepConfigurationNumber.Foreground = Get-Brush "#AEB8C2"
        $StepConfigurationText.Foreground = Get-Brush "#D6DEE5"
        $StepInventoryNumber.Foreground = Get-Brush "#AEB8C2"
        $StepInventoryText.Foreground = Get-Brush "#D6DEE5"
        $StepReview.Background = Get-Brush "#263746"
        $StepReviewNumber.Foreground = Get-Brush "#62A8EA"
        $StepReviewText.Foreground = Get-Brush "#FFFFFF"
        $StepReviewText.FontWeight = "SemiBold"
        $SafeModeText.Text = "Le password sono mascherate per impostazione predefinita e visibili soltanto su richiesta; le modifiche restano in memoria."
    } else {
        $ImportPage.Visibility = "Visible"
        $StepConfigurationNumber.Foreground = Get-Brush "#AEB8C2"
        $StepConfigurationText.Foreground = Get-Brush "#D6DEE5"
        $StepInventoryNumber.Foreground = Get-Brush "#AEB8C2"
        $StepInventoryText.Foreground = Get-Brush "#D6DEE5"
        $StepReviewNumber.Foreground = Get-Brush "#AEB8C2"
        $StepReviewText.Foreground = Get-Brush "#D6DEE5"
        $StepImport.Background = Get-Brush "#263746"
        $StepImportNumber.Foreground = Get-Brush "#62A8EA"
        $StepImportText.Foreground = Get-Brush "#FFFFFF"
        $StepImportText.FontWeight = "SemiBold"
        $SafeModeText.Text = "GPGAuth e OpenPGP vengono eseguiti localmente. Ogni scrittura richiede dry-run e conferma esplicita."
    }

    if ($Page -ne "Review") {
        if ($null -ne $script:ReviewResult) {
            $StepReviewNumber.Foreground = Get-Brush "#62A8EA"
            $StepReviewText.Foreground = Get-Brush "#D6DEE5"
        } else {
            $StepReviewNumber.Foreground = Get-Brush "#667683"
            $StepReviewText.Foreground = Get-Brush "#667683"
        }
    }
    if ($Page -ne "Import") {
        if ($script:ImportCandidates.Count -gt 0) {
            $StepImportNumber.Foreground = Get-Brush "#62A8EA"
            $StepImportText.Foreground = Get-Brush "#D6DEE5"
        } else {
            $StepImportNumber.Foreground = Get-Brush "#667683"
            $StepImportText.Foreground = Get-Brush "#667683"
        }
    }
}

function Set-InventoryFilters($Result) {
    $Clients = @("Tutti i clienti") + @($Result.by_client.PSObject.Properties.Name)
    $Formats = @("Tutti i formati") + @($Result.by_extension.PSObject.Properties.Name)
    $ClientFilter.ItemsSource = $Clients
    $FormatFilter.ItemsSource = $Formats
    $ClientFilter.SelectedIndex = 0
    $FormatFilter.SelectedIndex = 0
    $SearchBox.Text = ""
}

function Apply-InventoryFilters {
    if ($null -eq $script:InventoryResult) { return }

    $SelectedClient = [string]$ClientFilter.SelectedItem
    $SelectedFormat = [string]$FormatFilter.SelectedItem
    $Search = $SearchBox.Text.Trim()
    $Rows = New-Object System.Collections.ObjectModel.ObservableCollection[object]

    foreach ($Row in $script:AllInventoryRows) {
        if ($SelectedClient -and $SelectedClient -ne "Tutti i clienti" -and $Row.Client -ne $SelectedClient) { continue }
        if ($SelectedFormat -and $SelectedFormat -ne "Tutti i formati" -and $Row.Extension -ne $SelectedFormat) { continue }
        if ($Search) {
            $Haystack = "$($Row.Client) $($Row.RelativePath)"
            if ($Haystack.IndexOf($Search, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        }
        $Rows.Add($Row)
    }

    $FilesGrid.ItemsSource = $Rows
    $FilterStatus.Text = "$($Rows.Count) di $($script:AllInventoryRows.Count) file"
}

function Update-ReviewSelectionState {
    $Count = $FilesGrid.SelectedItems.Count
    $ReviewSelectionButton.Content = "Rivedi selezionati ($Count)"
    $ReviewSelectionButton.IsEnabled = ($Count -gt 0 -and $Count -le 50)
    if ($Count -gt 50) {
        $ReviewSelectionButton.Content = "Massimo 50 file"
    }
}

function Set-ReviewFilters {
    $ReviewStatusFilter.ItemsSource = @("Tutti i candidati", "Pronti", "Da completare")
    $ReviewStatusFilter.SelectedIndex = 0
    $ReviewSearchBox.Text = ""
}

function Apply-ReviewFilters {
    if ($null -eq $script:ReviewResult) { return }
    $SelectedStatus = [string]$ReviewStatusFilter.SelectedItem
    $Search = $ReviewSearchBox.Text.Trim()
    $Rows = New-Object System.Collections.ObjectModel.ObservableCollection[object]
    foreach ($Row in $script:AllReviewRows) {
        if ($SelectedStatus -eq "Pronti" -and $Row.Status -ne "ready") { continue }
        if ($SelectedStatus -eq "Da completare" -and $Row.Status -ne "incomplete") { continue }
        if ($Search) {
            $Haystack = "$($Row.Client) $($Row.Title) $($Row.Username) $($Row.Uri) $($Row.Source)"
            if ($Haystack.IndexOf($Search, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        }
        $Rows.Add($Row)
    }
    $ReviewCandidatesGrid.ItemsSource = $Rows
    $ReviewFilterStatus.Text = "$($Rows.Count) di $($script:AllReviewRows.Count) candidati"
    Update-ImportSelectionState
}

function Show-ExcelPasswordDialog([string]$RelativePath, [switch]$Retry, [switch]$BuildOnly) {
    $Dialog = New-Object System.Windows.Window
    $Dialog.Title = if ($Retry) { "Password Excel non corretta" } else { "Password Excel richiesta" }
    $Dialog.Width = 560
    $Dialog.Height = 300
    $Dialog.MinWidth = 500
    $Dialog.MinHeight = 280
    $Dialog.WindowStartupLocation = "CenterOwner"
    if (-not $BuildOnly -and $Window.IsVisible) { $Dialog.Owner = $Window }
    $Dialog.Background = Get-Brush "#F4F6F8"
    $Dialog.FontFamily = "Segoe UI"

    $Layout = New-Object System.Windows.Controls.Grid
    $Layout.Margin = [System.Windows.Thickness]::new(22)
    foreach ($Height in @("Auto", "Auto", "Auto", "*", "Auto")) {
        $Definition = New-Object System.Windows.Controls.RowDefinition
        $Definition.Height = if ($Height -eq "*") { [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star) } else { [System.Windows.GridLength]::Auto }
        [void]$Layout.RowDefinitions.Add($Definition)
    }

    $Title = New-Object System.Windows.Controls.TextBlock
    $Title.Text = if ($Retry) { "La password inserita non ha aperto il file" } else { "Questo file Excel e' protetto da password" }
    $Title.FontSize = 20
    $Title.FontWeight = "Bold"
    [void]$Layout.Children.Add($Title)
    $Description = New-Object System.Windows.Controls.TextBlock
    $Description.Text = "$RelativePath`nInserisci la password del file. Verra' usata soltanto in memoria per revisione, controlli di integrita' e importazione."
    $Description.TextWrapping = "Wrap"
    $Description.Foreground = Get-Brush "#66737F"
    $Description.Margin = [System.Windows.Thickness]::new(0, 7, 0, 14)
    [System.Windows.Controls.Grid]::SetRow($Description, 1)
    [void]$Layout.Children.Add($Description)

    $PasswordHost = New-Object System.Windows.Controls.Grid
    [System.Windows.Controls.Grid]::SetRow($PasswordHost, 2)
    $PasswordBox = New-Object System.Windows.Controls.PasswordBox
    $PasswordBox.MaxLength = 1024
    $PasswordText = New-Object System.Windows.Controls.TextBox
    $PasswordText.MaxLength = 1024
    $PasswordText.Visibility = "Collapsed"
    [void]$PasswordHost.Children.Add($PasswordBox)
    [void]$PasswordHost.Children.Add($PasswordText)
    [void]$Layout.Children.Add($PasswordHost)

    $ShowPassword = New-Object System.Windows.Controls.CheckBox
    $ShowPassword.Content = "Mostra password durante l'inserimento"
    $ShowPassword.Margin = [System.Windows.Thickness]::new(0, 8, 0, 0)
    [System.Windows.Controls.Grid]::SetRow($ShowPassword, 3)
    $ShowPassword.VerticalAlignment = "Top"
    $ShowPassword.Add_Checked({
        $PasswordText.Text = $PasswordBox.Password
        $PasswordBox.Visibility = "Collapsed"
        $PasswordText.Visibility = "Visible"
        $PasswordText.Focus() | Out-Null
        $PasswordText.CaretIndex = $PasswordText.Text.Length
    })
    $ShowPassword.Add_Unchecked({
        $PasswordBox.Password = $PasswordText.Text
        $PasswordText.Visibility = "Collapsed"
        $PasswordBox.Visibility = "Visible"
        $PasswordBox.Focus() | Out-Null
    })
    [void]$Layout.Children.Add($ShowPassword)

    $Footer = New-Object System.Windows.Controls.StackPanel
    $Footer.Orientation = "Horizontal"
    $Footer.HorizontalAlignment = "Right"
    [System.Windows.Controls.Grid]::SetRow($Footer, 4)
    $CancelButton = New-Object System.Windows.Controls.Button
    $CancelButton.Content = "Annulla revisione"
    $CancelButton.IsCancel = $true
    $CancelButton.Padding = [System.Windows.Thickness]::new(16, 8, 16, 8)
    $CancelButton.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    $CancelButton.Add_Click({ $Dialog.DialogResult = $false })
    $ContinueButton = New-Object System.Windows.Controls.Button
    $ContinueButton.Content = "Apri file Excel"
    $ContinueButton.IsDefault = $true
    $ContinueButton.Padding = [System.Windows.Thickness]::new(16, 8, 16, 8)
    $ContinueButton.Background = Get-Brush "#2878D0"
    $ContinueButton.Foreground = Get-Brush "#FFFFFF"
    $ContinueButton.BorderThickness = [System.Windows.Thickness]::new(0)
    $ContinueButton.Add_Click({
        $Password = if ([bool]$ShowPassword.IsChecked) { [string]$PasswordText.Text } else { [string]$PasswordBox.Password }
        if (-not $Password) {
            [System.Windows.MessageBox]::Show("Inserire la password del file Excel.", "Password mancante", "OK", "Warning") | Out-Null
            return
        }
        $Dialog.Tag = $Password
        $Dialog.DialogResult = $true
    })
    [void]$Footer.Children.Add($CancelButton)
    [void]$Footer.Children.Add($ContinueButton)
    [void]$Layout.Children.Add($Footer)
    $Dialog.Content = $Layout

    if ($BuildOnly) {
        return [pscustomobject]@{ Window = $Dialog; PasswordBox = $PasswordBox; PasswordText = $PasswordText; ShowPassword = $ShowPassword }
    }
    $PasswordBox.Focus() | Out-Null
    if ($Dialog.ShowDialog() -ne $true) {
        $PasswordBox.Clear()
        $PasswordText.Text = ""
        return $null
    }
    $Result = [string]$Dialog.Tag
    $Dialog.Tag = $null
    $PasswordBox.Clear()
    $PasswordText.Text = ""
    return $Result
}

function Invoke-SecureExcelReview([string[]]$Files, [hashtable]$Passwords) {
    $PasswordEntries = New-Object System.Collections.Generic.List[object]
    foreach ($RelativePath in @($Passwords.Keys | Sort-Object)) {
        $PasswordEntries.Add([pscustomobject][ordered]@{
            relative_path = [string]$RelativePath
            password = [string]$Passwords[$RelativePath]
        })
    }
    $Request = [pscustomobject]@{
        files = $Files
        file_passwords = $PasswordEntries.ToArray()
    }
    try {
        $Envelope = Invoke-SecureJsonProcess $PythonExecutable @($ReviewScript, "--secure-json", "--root", $script:InventoryFolder) $Request
        if (-not [bool]$Envelope.ok) { throw (Get-SecureErrorMessage $Envelope) }
        return $Envelope.result
    } finally {
        foreach ($Entry in $PasswordEntries) { $Entry.password = $null }
        $Request.file_passwords = $null
        $PasswordEntries.Clear()
        $Request = $null
    }
}

function Invoke-SelectedReview {
    $SelectedCount = $FilesGrid.SelectedItems.Count
    if ($SelectedCount -lt 1) { return }
    if ($SelectedCount -gt 50) {
        [System.Windows.MessageBox]::Show("Selezionare al massimo 50 file per ogni revisione.", "Troppi file selezionati", "OK", "Warning") | Out-Null
        return
    }

    $Decision = [System.Windows.MessageBox]::Show(
        "La revisione aprira' localmente soltanto i $SelectedCount file selezionati. Le password saranno riconosciute in memoria ma resteranno mascherate e non verranno salvate. Continuare?",
        "Autorizza analisi locale",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning
    )
    if ($Decision -ne [System.Windows.MessageBoxResult]::Yes) { return }

    Set-ReviewPasswordsVisible $false
    $Arguments = New-Object System.Collections.Generic.List[string]
    $Arguments.Add("--root")
    $Arguments.Add($script:InventoryFolder)
    $Arguments.Add("--json")
    $SelectedFiles = New-Object System.Collections.Generic.List[string]
    foreach ($SelectedItem in $FilesGrid.SelectedItems) {
        $Arguments.Add("--file")
        $Arguments.Add([string]$SelectedItem.RelativePath)
        $SelectedFiles.Add([string]$SelectedItem.RelativePath)
    }

    $ReviewSelectionButton.IsEnabled = $false
    $ReviewSelectionButton.Content = "Analisi locale in corso..."
    Add-Activity "Avvio revisione locale di $SelectedCount file selezionati."
    Update-Ui
    $script:ReviewFilePasswords = @{}
    $ExcelPasswords = @{}
    try {
        $Result = Invoke-PythonJson $ReviewScript ($Arguments.ToArray())
        $PromptAttempts = 0
        while (@($Result.protected_excel_issues).Count -gt 0) {
            $PromptAttempts++
            if ($PromptAttempts -gt 10) {
                throw "Impossibile completare la lettura dei file Excel protetti dopo troppi tentativi."
            }
            foreach ($Issue in @($Result.protected_excel_issues)) {
                $RelativePath = [string]$Issue.relative_path
                $IssueStatus = [string]$Issue.status
                if ($IssueStatus -eq "reader_unavailable") {
                    throw "Il lettore dei file Excel cifrati non e' installato. Eseguire: python -m pip install -r requirements.txt"
                }
                if ($IssueStatus -notin @("password_required", "password_rejected")) {
                    throw "Il file Excel protetto $RelativePath non puo essere letto in sicurezza."
                }
                $Password = Show-ExcelPasswordDialog $RelativePath -Retry:($IssueStatus -eq "password_rejected")
                if ($null -eq $Password) {
                    $ExcelPasswords.Clear()
                    Add-Activity "Revisione annullata durante la richiesta della password di un file Excel."
                    return
                }
                $ExcelPasswords[$RelativePath] = [string]$Password
                $Password = $null
            }
            Add-Activity "Nuovo tentativo di lettura locale di $($ExcelPasswords.Count) file Excel protetti; nessuna password e' stata registrata."
            $Result = Invoke-SecureExcelReview ($SelectedFiles.ToArray()) $ExcelPasswords
        }
        $script:ReviewFilePasswords = @{}
        foreach ($RelativePath in $ExcelPasswords.Keys) {
            $script:ReviewFilePasswords[[string]$RelativePath] = [string]$ExcelPasswords[$RelativePath]
        }
        $ExcelPasswords.Clear()
        $ReviewRows = New-Object System.Collections.Generic.List[object]
        if ($null -ne $Result.candidates) {
            foreach ($Candidate in @($Result.candidates)) {
                $StatusLabel = if ($Candidate.status -eq "ready") { "Pronto" } else { "Da completare" }
                $SecretDisplay = if ($Candidate.secret_present) { "******** ($($Candidate.secret_length))" } else { "Mancante" }
                $SourceAtRoot = -not [bool][System.IO.Path]::GetDirectoryName([string]$Candidate.source_relative_path)
                $Row = [pscustomobject]@{
                    CandidateId = [string]$Candidate.candidate_id
                    Status = [string]$Candidate.status
                    StatusLabel = $StatusLabel
                    Client = [string]$Candidate.client
                    Title = [string]$Candidate.title
                    Username = [string]$Candidate.username
                    Uri = [string]$Candidate.uri
                    OriginalClient = [string]$Candidate.client
                    OriginalSourceAtRoot = $SourceAtRoot
                    OriginalTitle = [string]$Candidate.title
                    OriginalUsername = [string]$Candidate.username
                    OriginalUri = [string]$Candidate.uri
                    SecretPresent = [bool]$Candidate.secret_present
                    SecretLength = [int]$Candidate.secret_length
                    SecretValue = ""
                    SecretCachedFromSource = $false
                    PasswordOverridden = $false
                    IsEdited = $false
                    SourcePasswordRequired = [bool]$Candidate.source_password_required
                    SecretDisplay = $SecretDisplay
                    Source = "$($Candidate.source_relative_path) - $($Candidate.location)"
                    SourceRelativePath = [string]$Candidate.source_relative_path
                    Location = [string]$Candidate.location
                    SourceHash = [string]$Candidate.source_sha256
                    Confidence = [string]$Candidate.confidence
                }
                Update-ReviewRowState $Row
                $ReviewRows.Add($Row)
            }
        }
        $script:ReviewResult = $Result
        $script:AllReviewRows = $ReviewRows.ToArray()
        Reset-ImportWorkflow
        $ReviewMetricFiles.Text = "$($Result.analyzed_files)/$($Result.selected_files)"
        Update-ReviewMetrics
        $ReviewSummary.Text = "Revisione locale completata $(Get-Date -Format 'dd/MM/yyyy HH:mm')"
        Set-ReviewFilters
        Apply-ReviewFilters

        $WarningItems = @($Result.warnings)
        if ($WarningItems.Count -gt 0) {
            $ShownWarnings = @($WarningItems | Select-Object -First 5)
            $ReviewWarningsText.Text = $ShownWarnings -join [Environment]::NewLine
            if ($WarningItems.Count -gt 5) {
                $ReviewWarningsText.Text += [Environment]::NewLine + "... e altri $($WarningItems.Count - 5) avvisi."
            }
            $ReviewWarningsPanel.Visibility = "Visible"
        } else {
            $ReviewWarningsPanel.Visibility = "Collapsed"
        }
        Add-Activity "Revisione completata: $($Result.candidate_count) candidati; valori segreti non registrati."
        Show-Page "Review"
    } catch {
        $script:ReviewFilePasswords = @{}
        $ExcelPasswords.Clear()
        Add-Activity "Revisione non riuscita: $($_.Exception.Message)"
        [System.Windows.MessageBox]::Show($_.Exception.Message, "Revisione non riuscita", "OK", "Error") | Out-Null
    } finally {
        $ExcelPasswords.Clear()
        Update-ReviewSelectionState
    }
}

function Invoke-Inventory {
    $Folder = $ClientFolder.Text.Trim()
    if (-not (Test-Path -LiteralPath $Folder -PathType Container)) {
        [System.Windows.MessageBox]::Show("La cartella configurata non $([char]0x00E8) pi$([char]0x00F9) accessibile.", "Cartella non disponibile", "OK", "Warning") | Out-Null
        Show-Page "Configuration"
        Update-ConfigurationState
        return
    }

    $script:ReviewResult = $null
    $script:AllReviewRows = @()
    $script:ReviewFilePasswords = @{}
    Reset-ImportWorkflow
    $ReviewCandidatesGrid.ItemsSource = $null
    $StepReviewNumber.Foreground = Get-Brush "#667683"
    $StepReviewText.Foreground = Get-Brush "#667683"
    $RefreshButton.IsEnabled = $false
    $ExportButton.IsEnabled = $false
    $InventoryRoot.Text = "Analisi dei metadati in corso: $Folder"
    $FilesGrid.ItemsSource = $null
    $FilterStatus.Text = "Analisi in corso..."
    Add-Activity "Avvio inventario metadati."
    Update-Ui

    try {
        $Result = Invoke-PythonJson $InventoryScript @("--inventory", $Folder, "--json")
        $script:InventoryResult = $Result
        $script:InventoryFolder = $Folder
        $RowList = New-Object System.Collections.Generic.List[object]
        if ($null -ne $Result.items) {
            foreach ($Item in @($Result.items)) {
                $Modified = ""
                if ($Item.modified_utc) {
                    try { $Modified = ([DateTimeOffset]::Parse([string]$Item.modified_utc)).ToLocalTime().ToString("dd/MM/yyyy HH:mm") } catch { $Modified = [string]$Item.modified_utc }
                }
                $RowList.Add([pscustomobject]@{
                    Client = [string]$Item.client
                    RelativePath = [string]$Item.relative_path
                    Extension = [string]$Item.extension
                    Category = [string]$Item.category
                    Size = Format-Size ([long]$Item.size_bytes)
                    SizeBytes = [long]$Item.size_bytes
                    Modified = $Modified
                    IsLink = [bool]$Item.is_link
                })
            }
        }
        # Windows PowerShell 5.1 throws "Argument types do not match" when a
        # generic List[object] is expanded with @($RowList). ToArray() avoids
        # that legacy binder bug and gives the DataGrid a regular object array.
        $script:AllInventoryRows = $RowList.ToArray()
        $MetricClients.Text = [string]$Result.client_folders
        $MetricFiles.Text = [string]$Result.supported_files
        $MetricSize.Text = Format-Size ([long]$Result.supported_bytes)
        $MetricIgnored.Text = [string]$Result.ignored_files
        $InventoryRoot.Text = "Cartella: $($Result.root) $([char]0x2022) inventario aggiornato $(Get-Date -Format 'dd/MM/yyyy HH:mm')"
        Set-InventoryFilters $Result
        Apply-InventoryFilters

        $ErrorCount = @($Result.access_errors).Count
        $LinkCount = @($script:AllInventoryRows | Where-Object { $_.IsLink }).Count
        $DirectoryLinkCount = @($Result.skipped_directory_links).Count
        $Warnings = @()
        if ($ErrorCount -gt 0) { $Warnings += "$ErrorCount percorsi non accessibili: il report potrebbe essere incompleto." }
        if ($LinkCount -gt 0) { $Warnings += "$LinkCount collegamenti a file individuati; $([char]0x00E8) stato letto solo il metadato del collegamento." }
        if ($DirectoryLinkCount -gt 0) { $Warnings += "$DirectoryLinkCount collegamenti a cartelle ignorati per mantenere l'inventario entro la radice selezionata." }
        if ($Warnings.Count -gt 0) {
            $WarningsText.Text = $Warnings -join "  "
            $WarningsPanel.Visibility = "Visible"
        } else {
            $WarningsPanel.Visibility = "Collapsed"
        }

        $ExportButton.IsEnabled = $true
        Add-Activity "Inventario completato: $($Result.client_folders) clienti, $($Result.supported_files) file supportati, $($Result.ignored_files) ignorati."
    } catch {
        $script:InventoryResult = $null
        $script:AllInventoryRows = @()
        $InventoryRoot.Text = "Inventario non riuscito"
        $FilterStatus.Text = "0 file"
        Add-Activity "Inventario non riuscito: $($_.Exception.Message)"
        [System.Windows.MessageBox]::Show($_.Exception.Message, "Inventario non riuscito", "OK", "Error") | Out-Null
    } finally {
        $RefreshButton.IsEnabled = $true
        Update-ReviewSelectionState
    }
}

$PassboltUrl.Add_TextChanged({
    if ($script:VerifiedUrl -and $PassboltUrl.Text.Trim() -ne $script:VerifiedUrl) {
        if (Test-ImportSessionActive) {
            Stop-ImportSession "Sessione chiusa perche' l'URL Passbolt e' stato modificato." $false
        }
        $script:ConnectionVerified = $false
        $script:VerifiedUrl = ""
        $script:VerifiedFingerprint = ""
        $DetectedFingerprint.Text = "Non ancora rilevata"
        Reset-ImportPlan "URL Passbolt modificato. Ripetere connessione e dry-run."
        $script:ClientDestinationMap = @{}
        Update-DestinationFolderOptions @() "" $false
        $ConnectionDot.Fill = Get-Brush "#98A5B1"
        $ConnectionStatus.Text = "URL modificato: ripetere la verifica"
        $ConnectionStatus.Foreground = Get-Brush "#66737F"
        Update-ConfigurationState
    }
})

$VerifyButton.Add_Click({
    $VerifyButton.IsEnabled = $false
    $ConnectionDot.Fill = Get-Brush "#B7791F"
    $ConnectionStatus.Text = "Verifica in corso..."
    $ConnectionStatus.Foreground = Get-Brush "#B7791F"
    Add-Activity "Avvio verifica pubblica dell'istanza Passbolt."
    Update-Ui
    try {
        $Url = $PassboltUrl.Text.Trim()
        $Result = Invoke-PythonJson $ProbeScript @("--base-url", $Url, "--discover-fingerprint", "--json")
        $DetectedValue = ([string]$Result.fingerprint).Trim().ToUpperInvariant()
        if ($DetectedValue -notmatch '^[0-9A-F]{40}$') {
            throw "La fingerprint rilevata dal server non e' valida."
        }
        $DetectedFingerprint.Text = $DetectedValue
        $ConfirmationMessage = "Fingerprint OpenPGP rilevata:`n`n$DetectedValue`n`nIl valore e' stato fornito dall'istanza appena contattata. Il rilevamento automatico non dimostra da solo l'identita' del server. Alla prima connessione, confrontarlo con l'amministratore tramite un canale indipendente.`n`nConfermare questa fingerprint per la sessione corrente?"
        $Confirmation = [System.Windows.MessageBox]::Show($ConfirmationMessage, "Conferma fingerprint Passbolt", "YesNo", "Warning")
        if ([string]$Confirmation -ne "Yes") {
            if (Test-ImportSessionActive) {
                Stop-ImportSession "Sessione chiusa perche' la fingerprint Passbolt rilevata non e' stata confermata." $false
            }
            $script:ConnectionVerified = $false
            $script:VerifiedUrl = ""
            $script:VerifiedFingerprint = ""
            Reset-ImportPlan "Fingerprint Passbolt non confermata. Ripetere la verifica."
            $script:ClientDestinationMap = @{}
            Update-DestinationFolderOptions @() "" $false
            $ConnectionDot.Fill = Get-Brush "#B7791F"
            $ConnectionStatus.Text = "Fingerprint rilevata ma non confermata"
            $ConnectionStatus.Foreground = Get-Brush "#B7791F"
            Add-Activity "Fingerprint Passbolt rilevata ma non confermata; connessione non autorizzata."
            return
        }
        if ((Test-ImportSessionActive) -and $script:VerifiedFingerprint -and $script:VerifiedFingerprint -ne $DetectedValue) {
            Stop-ImportSession "Sessione chiusa perche' la fingerprint Passbolt rilevata e' cambiata." $false
        }
        $script:ConnectionVerified = $true
        $script:VerifiedUrl = [string]$Result.base_url
        $script:VerifiedFingerprint = $DetectedValue
        if ($null -ne $script:ImportPlan) { Reset-ImportPlan "Connessione riverificata. Ripetere il dry-run autenticato." }
        $ConnectionDot.Fill = Get-Brush "#16875D"
        $ConnectionStatus.Text = "Connesso - fingerprint confermata: $DetectedValue"
        $ConnectionStatus.Foreground = Get-Brush "#16875D"
        Add-Activity "Passbolt raggiungibile; healthcheck verificato e fingerprint rilevata confermata dall'utente."
    } catch {
        $FailureMessage = [string]$_.Exception.Message
        if (Test-ImportSessionActive) {
            Stop-ImportSession "Sessione chiusa perche' la verifica pubblica di Passbolt non e' riuscita." $false
        }
        $script:ConnectionVerified = $false
        $script:VerifiedUrl = ""
        $script:VerifiedFingerprint = ""
        $DetectedFingerprint.Text = "Non disponibile"
        Reset-ImportPlan "Verifica pubblica non riuscita. Ripetere connessione e dry-run."
        $ConnectionDot.Fill = Get-Brush "#C43D4B"
        $ConnectionStatus.Text = "Verifica non riuscita"
        $ConnectionStatus.Foreground = Get-Brush "#C43D4B"
        Add-Activity "Verifica Passbolt non riuscita: $FailureMessage"
        [System.Windows.MessageBox]::Show($FailureMessage, "Connessione non riuscita", "OK", "Error") | Out-Null
    } finally {
        $VerifyButton.IsEnabled = $true
        Update-ConfigurationState
        Update-ImportSessionState
    }
})

$ClientFolder.Add_TextChanged({
    Update-ConfigurationState
    if ($script:InventoryFolder -and $ClientFolder.Text.Trim() -ne $script:InventoryFolder) {
        if (Test-ImportSessionActive) {
            Stop-ImportSession "Sessione chiusa perche' la cartella clienti e' stata modificata." $false
        }
        $script:InventoryResult = $null
        $script:AllInventoryRows = @()
        $script:ReviewResult = $null
        $script:AllReviewRows = @()
        Reset-ImportWorkflow
        $StepReviewNumber.Foreground = Get-Brush "#667683"
        $StepReviewText.Foreground = Get-Brush "#667683"
    }
})

$BrowseButton.Add_Click({
    $Dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $Dialog.Description = "Seleziona la cartella principale dei documenti clienti"
    $Dialog.ShowNewFolderButton = $false
    if ($ClientFolder.Text.Trim() -and (Test-Path -LiteralPath $ClientFolder.Text.Trim() -PathType Container)) {
        $Dialog.SelectedPath = $ClientFolder.Text.Trim()
    }
    if ($Dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $ClientFolder.Text = $Dialog.SelectedPath
        Add-Activity "Cartella clienti selezionata. Nessun documento $([char]0x00E8) stato aperto."
    }
    $Dialog.Dispose()
})

$ContinueButton.Add_Click({
    if (-not ($script:ConnectionVerified -and (Test-SelectedFolder))) {
        [System.Windows.MessageBox]::Show("Completare la verifica della connessione e selezionare una cartella valida.", "Configurazione incompleta", "OK", "Warning") | Out-Null
        return
    }
    Show-Page "Inventory"
    if ($null -eq $script:InventoryResult -or $script:InventoryFolder -ne $ClientFolder.Text.Trim()) {
        Invoke-Inventory
    } else {
        Apply-InventoryFilters
    }
})

$BackButton.Add_Click({ Show-Page "Configuration"; Update-ConfigurationState })
$StepConfiguration.Add_MouseLeftButtonUp({ Show-Page "Configuration"; Update-ConfigurationState })
$StepInventory.Add_MouseLeftButtonUp({
    if ($script:ConnectionVerified -and (Test-SelectedFolder)) {
        Show-Page "Inventory"
        if ($null -eq $script:InventoryResult -or $script:InventoryFolder -ne $ClientFolder.Text.Trim()) { Invoke-Inventory }
    }
})
$StepReview.Add_MouseLeftButtonUp({
    if ($null -ne $script:ReviewResult) { Show-Page "Review" }
})
$StepImport.Add_MouseLeftButtonUp({
    if ($script:ImportCandidates.Count -gt 0) { Show-Page "Import" }
})
$RefreshButton.Add_Click({ Invoke-Inventory })
$ClientFilter.Add_SelectionChanged({ Apply-InventoryFilters })
$FormatFilter.Add_SelectionChanged({ Apply-InventoryFilters })
$SearchBox.Add_TextChanged({ Apply-InventoryFilters })
$FilesGrid.Add_SelectionChanged({ Update-ReviewSelectionState })
$ReviewSelectionButton.Add_Click({ Invoke-SelectedReview })
$ReviewBackButton.Add_Click({ Show-Page "Inventory"; Apply-InventoryFilters })
$ReviewStatusFilter.Add_SelectionChanged({ Apply-ReviewFilters })
$ReviewSearchBox.Add_TextChanged({ Apply-ReviewFilters })
$ReviewCandidatesGrid.Add_SelectionChanged({ Update-ImportSelectionState })
$ReviewPasswordToggle.Add_Checked({
    if (-not $script:UpdatingReviewPasswordToggle) { Set-ReviewPasswordsVisible $true }
})
$ReviewPasswordToggle.Add_Unchecked({
    if (-not $script:UpdatingReviewPasswordToggle) { Set-ReviewPasswordsVisible $false }
})
$EditReviewCandidateButton.Add_Click({ Show-ReviewCandidateEditor })
$PrepareImportButton.Add_Click({ Open-ImportPreparation })
$ImportBackButton.Add_Click({ Show-Page "Review"; Apply-ReviewFilters })

$BrowseKeyButton.Add_Click({
    $Dialog = New-Object System.Windows.Forms.OpenFileDialog
    $Dialog.Title = "Seleziona la chiave privata OpenPGP di Passbolt"
    $Dialog.Filter = "Chiavi OpenPGP (*.asc;*.key)|*.asc;*.key|Tutti i file (*.*)|*.*"
    $Dialog.CheckFileExists = $true
    $Dialog.Multiselect = $false
    if ($PrivateKeyPath.Text.Trim() -and (Test-Path -LiteralPath $PrivateKeyPath.Text.Trim() -PathType Leaf)) {
        $Dialog.FileName = $PrivateKeyPath.Text.Trim()
    }
    try {
        if ($Dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $PrivateKeyPath.Text = $Dialog.FileName
            Add-Activity "File della chiave privata selezionato; il contenuto non e' stato copiato."
        }
    } finally {
        $Dialog.Dispose()
    }
})

$PrivateKeyPath.Add_TextChanged({
    if ($script:ImportPlanKeyPath -and $PrivateKeyPath.Text.Trim() -ne $script:ImportPlanKeyPath) {
        Reset-ImportPlan "Chiave privata modificata. Ripetere il dry-run."
    }
    Update-ExecuteImportState
})
$KeyPassphrase.Add_PasswordChanged({ Update-ImportSessionState })
$MfaTotpCode.Add_PasswordChanged({ Update-ImportSessionState })
$ResourceFormat.Add_SelectionChanged({
    if ($null -ne $script:ImportPlan) {
        Reset-ImportPlan "Il formato risorsa e' cambiato. Ripetere il dry-run."
        Add-Activity "Formato risorsa modificato; il piano precedente e' stato invalidato."
    }
})
$FolderFormat.Add_SelectionChanged({
    if ($null -ne $script:ImportPlan) {
        Reset-ImportPlan "Il formato cartelle e' cambiato. Ripetere il dry-run."
        Add-Activity "Formato cartelle modificato; il piano precedente e' stato invalidato."
    }
})
$DestinationMode.Add_SelectionChanged({
    Update-DestinationControlState
    if ($null -ne $script:ImportPlan) {
        Reset-ImportPlan "La destinazione e' cambiata. Ripetere il dry-run."
        Add-Activity "Destinazione modificata; il piano precedente e' stato invalidato."
    }
})
$DestinationFolder.Add_SelectionChanged({
    if (-not $script:PopulatingDestinationFolders -and $null -ne $script:ImportPlan) {
        Reset-ImportPlan "La cartella Passbolt di destinazione e' cambiata. Ripetere il dry-run."
        Add-Activity "Cartella Passbolt modificata; il piano precedente e' stato invalidato."
    }
})
$ConfigureClientMappingsButton.Add_Click({ Show-ClientDestinationMappingDialog })
$ImportConfirmation.Add_TextChanged({ Update-ExecuteImportState })
$ImportSessionButton.Add_Click({
    if (Test-ImportSessionActive) {
        Stop-ImportSession "Sessione autenticata chiusa dall'utente." $true
    } elseif ($null -ne $script:ImportSessionProcess -or $script:ImportSessionId) {
        Stop-ImportSession "La sessione locale non era piu disponibile ed e' stata ripulita. Avviarne una nuova." $true
    } else {
        Open-ImportSession
    }
})
$DryRunButton.Add_Click({ Invoke-ImportReadiness })
$ExecuteImportButton.Add_Click({ Invoke-ConfirmedImport })

$ExportButton.Add_Click({
    if ($null -eq $script:InventoryResult) { return }
    $Dialog = New-Object System.Windows.Forms.SaveFileDialog
    $Dialog.Title = "Esporta inventario metadati"
    $Dialog.Filter = "File CSV (*.csv)|*.csv"
    $Dialog.DefaultExt = "csv"
    $Dialog.AddExtension = $true
    $Dialog.OverwritePrompt = $true
    $Dialog.FileName = "inventario-passbolt-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
    try {
        if ($Dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $ExportButton.IsEnabled = $false
            Add-Activity "Esportazione CSV in corso."
            Update-Ui
            $ExportResult = Invoke-PythonJson $InventoryScript @("--inventory", $script:InventoryFolder, "--csv", $Dialog.FileName, "--json")
            Add-Activity "Report CSV esportato: $($ExportResult.csv_path)"
            [System.Windows.MessageBox]::Show("Inventario esportato correttamente in:`n$($ExportResult.csv_path)", "Esportazione completata", "OK", "Information") | Out-Null
        }
    } catch {
        Add-Activity "Esportazione non riuscita: $($_.Exception.Message)"
        [System.Windows.MessageBox]::Show($_.Exception.Message, "Esportazione non riuscita", "OK", "Error") | Out-Null
    } finally {
        $Dialog.Dispose()
        if ($null -ne $script:InventoryResult) { $ExportButton.IsEnabled = $true }
    }
})

$script:ImportSessionTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:ImportSessionTimer.Interval = [TimeSpan]::FromMinutes(1)
$script:ImportSessionTimer.Add_Tick({
    if (($null -ne $script:ImportSessionProcess -or $script:ImportSessionId) -and -not (Test-ImportSessionActive)) {
        Stop-ImportSession "La sessione locale si e' chiusa inaspettatamente ed e' stata ripulita." $true
    } elseif ((Test-ImportSessionActive) -and $script:ImportSessionLastActivityUtc -ne [DateTime]::MinValue) {
        $IdleMinutes = ([DateTime]::UtcNow - $script:ImportSessionLastActivityUtc).TotalMinutes
        if ($IdleMinutes -ge $script:ImportSessionIdleTimeoutMinutes) {
            Stop-ImportSession "Sessione autenticata chiusa automaticamente dopo $($script:ImportSessionIdleTimeoutMinutes) minuti di inattivita'." $true
        }
    }
})
$script:ImportSessionTimer.Start()

$Window.Add_Closing({
    $script:ClosingApplication = $true
    foreach ($Row in $script:AllReviewRows) {
        $Row.SecretValue = ""
        $Row.SecretCachedFromSource = $false
    }
    $script:ImportSecretOverrides = @{}
    $script:ReviewFilePasswords = @{}
    $script:ImportSourceFilePasswords = @{}
    if ($null -ne $script:ImportSessionTimer) { $script:ImportSessionTimer.Stop() }
    Stop-ImportSession "" $false
})

Update-DestinationControlState
Update-ImportSessionState
Add-Activity "Applicazione pronta. Nessun documento $([char]0x00E8) stato letto."
Update-ConfigurationState

if ($SelfTest) {
    $CompatibilityList = New-Object System.Collections.Generic.List[object]
    $CompatibilityList.Add([pscustomobject]@{ value = 1 })
    $CompatibilityArray = $CompatibilityList.ToArray()
    if ($CompatibilityArray.Count -ne 1) {
        throw "Verifica compatibilit$([char]0x00E0) collezioni Windows PowerShell non riuscita."
    }
    $ArgumentProbeValue = "C:\Cartella Con Spazi\"
    $ArgumentProbeCode = "import json,sys; print(json.dumps({'ok': True, 'result': {'argument': sys.argv[1]}}))"
    $ArgumentProbe = Invoke-SecureJsonProcess $PythonExecutable @("-c", $ArgumentProbeCode, $ArgumentProbeValue) ([pscustomobject]@{ test = $true }) 30000
    if (-not $ArgumentProbe.ok -or $ArgumentProbe.result.argument -ne $ArgumentProbeValue) {
        throw "Verifica degli argomenti di processo con spazi non riuscita."
    }
    $SessionProbeCode = @'
import json
import sys

for line in sys.stdin:
    request = json.loads(line)
    print(json.dumps({"ok": True, "result": {"command": request.get("command"), "session_id": request.get("session_id")}}), flush=True)
    if request.get("command") == "session-close":
        break
'@
    $SessionProbeStartInfo = New-Object System.Diagnostics.ProcessStartInfo
    $SessionProbeStartInfo.FileName = $PythonExecutable
    $SessionProbeStartInfo.Arguments = (@("-u", "-c", $SessionProbeCode) | ForEach-Object { ConvertTo-ProcessArgument ([string]$_) }) -join ' '
    $SessionProbeStartInfo.UseShellExecute = $false
    $SessionProbeStartInfo.CreateNoWindow = $true
    $SessionProbeStartInfo.RedirectStandardInput = $true
    $SessionProbeStartInfo.RedirectStandardOutput = $true
    $SessionProbeStartInfo.RedirectStandardError = $true
    $SessionProbeStartInfo.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $SessionProbeStartInfo.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
    $SessionProbeProcess = New-Object System.Diagnostics.Process
    $SessionProbeProcess.StartInfo = $SessionProbeStartInfo
    try {
        if (-not $SessionProbeProcess.Start()) { throw "Impossibile avviare il test del protocollo persistente." }
        $script:ImportSessionProcess = $SessionProbeProcess
        $script:ImportSessionErrorTask = $SessionProbeProcess.StandardError.ReadToEndAsync()
        $script:ImportSessionId = "transport-probe"
        $SessionProbeEnvelope = Invoke-ImportSessionJson ([pscustomobject]@{ command = "session-readiness"; session_id = "transport-probe" }) 30000
        if (-not $SessionProbeEnvelope.ok -or $SessionProbeEnvelope.result.command -ne "session-readiness" -or $SessionProbeEnvelope.result.session_id -ne "transport-probe") {
            throw "Il protocollo persistente dell'interfaccia non ha restituito la risposta prevista."
        }
    } finally {
        Stop-ImportSession "" $false
    }
    $ReviewBackendTest = Invoke-PythonJson $ReviewScript @("--self-test")
    if ($ReviewBackendTest.secrets_serialized -or -not $ReviewBackendTest.excel_password_prompt_supported) {
        throw "Il backend di revisione non rispetta il contratto di mascheramento."
    }
    $ImportBackendTest = Invoke-PythonJson $ImportScript @("--self-test")
    if (-not $ImportBackendTest.ok -or $ImportBackendTest.result.secrets_serialized -or -not $ImportBackendTest.result.persistent_session_protocol -or -not $ImportBackendTest.result.reconciliation_progress_protocol -or -not $ImportBackendTest.result.explicit_reveal_supported -or -not $ImportBackendTest.result.protected_excel_integrity_supported) {
        throw "Il backend di importazione non rispetta il contratto di sicurezza."
    }
    $CryptoBackendTest = Invoke-SecureJsonProcess $NodeExecutable @($CryptoScript) ([pscustomobject]@{ command = "self-test" }) 120000
    if (-not $CryptoBackendTest.ok -or $CryptoBackendTest.result.secrets_serialized -or -not $CryptoBackendTest.result.persistent_session_protocol -or -not $CryptoBackendTest.result.reconciliation_progress_protocol) {
        throw "Il bridge OpenPGP locale non ha superato il test di sicurezza."
    }
    if ([string]$ImportSessionButton.Content -ne "Avvia sessione" -or $script:ImportSessionIdleTimeoutMinutes -ne 30) {
        throw "I controlli UI della sessione autenticata non sono nello stato previsto."
    }
    if ($null -ne $Window.FindName("ServerFingerprint") -or [string]$DetectedFingerprint.Text -ne "Non ancora rilevata") {
        throw "La configurazione deve rilevare la fingerprint senza richiedere un inserimento manuale."
    }
    $script:ImportCandidates = @(
        [pscustomobject]@{ client = "Cliente Alfa" },
        [pscustomobject]@{ client = "Cliente Beta" }
    )
    $script:AvailableDestinationFolders = @(
        [pscustomobject]@{ id = "folder-alpha-id"; path = "Clienti / Cliente Alfa" }
    )
    $script:DestinationFolderCatalogLoaded = $true
    $script:ClientDestinationMap = @{
        "Cliente Alfa" = "folder-alpha-id"
        "Cliente Beta" = "__root__"
    }
    $ClientMappingProbe = @(Get-ClientDestinationMappingPayload)
    if ($ClientMappingProbe.Count -ne 2 -or @($ClientMappingProbe | Where-Object { $null -eq $_.folder_id }).Count -ne 1) {
        throw "La mappatura UI delle destinazioni per cliente non e' valida."
    }
    $DestinationMode.SelectedIndex = 1
    Update-DestinationControlState
    if (-not $ConfigureClientMappingsButton.IsEnabled -or $ConfigureClientMappingsButton.Visibility -ne "Visible") {
        throw "I controlli UI della mappatura per cliente non sono nello stato previsto."
    }
    $ClientMappingDialogProbe = Show-ClientDestinationMappingDialog -BuildOnly
    if ($null -eq $ClientMappingDialogProbe -or $ClientMappingDialogProbe.Editors.Count -ne 2) {
        throw "La finestra UI della mappatura per cliente non puo essere costruita."
    }
    $ClientMappingDialogProbe.Window.Close()
    if ([bool]$ReviewPasswordToggle.IsChecked -or [string]$ReviewPasswordState.Text -ne "PASSWORD MASCHERATE") {
        throw "Il controllo di visualizzazione password non e' mascherato per impostazione predefinita."
    }
    $ExcelPasswordDialogProbe = Show-ExcelPasswordDialog "Cliente Alfa/credenziali.xlsx" -BuildOnly
    if ($null -eq $ExcelPasswordDialogProbe -or $ExcelPasswordDialogProbe.PasswordBox.MaxLength -ne 1024 -or $ExcelPasswordDialogProbe.PasswordText.Visibility -ne "Collapsed") {
        throw "La richiesta protetta della password Excel non puo essere costruita nello stato previsto."
    }
    $ExcelPasswordDialogProbe.Window.Close()
    $ReviewEditorRowProbe = [pscustomobject]@{
        CandidateId = "review-editor-probe"
        Client = "Cliente Alfa"
        Title = "Portale"
        Username = "utente"
        Uri = "10.0.0.1"
        OriginalClient = "Cliente Alfa"
        OriginalSourceAtRoot = $false
        OriginalTitle = "Portale"
        OriginalUsername = "utente"
        OriginalUri = "10.0.0.1"
        SecretPresent = $true
        SecretLength = 16
        SecretValue = "self-test-secret"
        SecretCachedFromSource = $true
        PasswordOverridden = $false
        IsEdited = $false
        Status = "ready"
        StatusLabel = "Pronto"
        SecretDisplay = "******** (16)"
        SourcePasswordRequired = $false
        SourceRelativePath = "Cliente Alfa/portale.txt"
        SourceHash = ("a" * 64)
    }
    $ReviewEditorProbe = Show-ReviewCandidateEditor $ReviewEditorRowProbe -BuildOnly
    if ($null -eq $ReviewEditorProbe -or $ReviewEditorProbe.Editors.Count -ne 5) {
        throw "L'editor dei candidati non espone i cinque campi previsti."
    }
    $ReviewEditorProbe.Window.Close()
    [pscustomobject]@{
        app = "Passbolt Migration Assistant"
        version = "0.12.5"
        ui = "WPF"
        phases = 4
        controls = 76
        inventory_collection = "OK"
        review_backend = "OK"
        import_backend = "OK"
        openpgp_backend = "OK"
        process_argument_quoting = "OK"
        persistent_process_transport = "OK"
        client_mapping_ui = "OK"
        review_password_toggle = "OK"
        review_candidate_editor = "OK"
        protected_excel_password_prompt = "OK"
        persistent_import_session = "OK"
        reconciliation_progress_protocol = "OK"
        mfa_reused_without_reprompt = "OK"
        automatic_fingerprint_confirmation = "OK"
        secrets_serialized = $false
        python = $PythonExecutable
        node = $NodeExecutable
        status = "OK"
    } | ConvertTo-Json
    $Window.Close()
    exit 0
}

$Window.ShowDialog() | Out-Null
